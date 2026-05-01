// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from
    "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CollateralManager} from "./CollateralManager.sol";
import {LendingConstants} from "./libraries/LendingConstants.sol";

/**
 * @title BorrowEngine
 * @notice Tracks debt positions, accrues interest, and calculates health factors.
 * @dev Only LendingPool can call borrow/repay. Uses a global borrow index
 *      for O(1) interest accrual — no loops over users needed.
 */
contract BorrowEngine is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────

    /// @dev The token users borrow (USDC)
    IERC20 private s_borrowToken;

    /// @dev Needed to read collateral USD value for health factor
    CollateralManager private s_collateralManager;

    /// @dev Only this address can call borrow(), repay(), and repayOnBehalf()
    address private s_lendingPool;

    /**
     * @dev Global interest multiplier — starts at 1e18 (= 1.0)
     *      Increases every second based on the borrow rate.
     *      Every user's debt is scaled by this index at repay time.
     */
    uint256 private s_borrowIndex;

    /// @dev Unix timestamp of the last index update
    uint256 private s_lastUpdateTimestamp;

    /**
     * @dev Annual borrow rate in 1e18 precision.
     *      5% APR = 5e16 (0.05 × 1e18)
     *      Per-second rate = APR / SECONDS_PER_YEAR
     */
    uint256 private s_borrowRatePerSecond;

    /// @dev Seconds in a year — used to convert APR to per-second rate
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /**
     * @dev Principal debt each user owes in borrow token units.
     *      Stored as principal only — multiply by index ratio to get actual debt.
     */
    mapping(address user => uint256 principal) private s_userDebt;

    /**
     * @dev The borrow index value at the time each user last borrowed or repaid.
     *      Used to calculate interest: debtWithInterest = principal × (currentIndex / userIndex)
     */
    mapping(address user => uint256 index) private s_userBorrowIndex;

    // ─── Events ───────────────────────────────────────────────────

    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount, uint256 remaining);
    event BorrowRateUpdated(uint256 newRatePerSecond);
    event IndexUpdated(uint256 newIndex, uint256 timestamp);

    // ─── Errors ───────────────────────────────────────────────────

    error BorrowEngine__NotLendingPool(address caller);
    error BorrowEngine__ZeroAmount();
    error BorrowEngine__ZeroAddress();
    error BorrowEngine__LendingPoolAlreadySet();
    error BorrowEngine__HealthFactorTooLow(uint256 healthFactor);
    error BorrowEngine__RepayExceedsDebt(uint256 repayAmount, uint256 totalDebt);
    error BorrowEngine__InsufficientLiquidity(uint256 requested, uint256 available);

    // ─── Modifier ─────────────────────────────────────────────────

    modifier onlyLendingPool() {
        if (msg.sender != s_lendingPool) {
            revert BorrowEngine__NotLendingPool(msg.sender);
        }
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ──────────────────────────────────────────────

    /**
     * @notice Sets up the borrow engine.
     * @param borrowToken        The ERC20 users will borrow (USDC)
     * @param collateralManager  For reading collateral USD value
     * @param initialApr         Annual borrow rate in 1e18 precision (5% = 5e16)
     * @param admin              Protocol owner
     */
    function initialize(
        address borrowToken,
        address collateralManager,
        uint256 initialApr,
        address admin
    ) external initializer {
        if (
            borrowToken == address(0) ||
            collateralManager == address(0) ||
            admin == address(0)
        ) revert BorrowEngine__ZeroAddress();

        __Ownable_init(admin);

        s_borrowToken = IERC20(borrowToken);
        s_collateralManager = CollateralManager(collateralManager);

        // Index starts at 1.0 — no interest has accrued yet
        s_borrowIndex = LendingConstants.PRECISION;
        s_lastUpdateTimestamp = block.timestamp;

        // Convert APR to per-second rate: rate/second = APR / SECONDS_PER_YEAR
        s_borrowRatePerSecond = initialApr / SECONDS_PER_YEAR;
    }

    // ─── Setup ────────────────────────────────────────────────────

    /**
     * @notice Wires the LendingPool address. Called once after deployment.
     * @param lendingPool The deployed LendingPool address
     */
    function setLendingPool(address lendingPool) external onlyOwner {
        if (s_lendingPool != address(0)) {
            revert BorrowEngine__LendingPoolAlreadySet();
        }
        if (lendingPool == address(0)) revert BorrowEngine__ZeroAddress();
        s_lendingPool = lendingPool;
    }

    // ─── External — called by LendingPool only ────────────────────

    /**
     * @notice Lends `amount` of borrow token to `user` if health factor stays safe.
     *
     * Flow:
     *   1. Accrue interest globally (update index)
     *   2. Check the protocol has enough liquidity
     *   3. Simulate the new debt and calculate health factor
     *   4. Revert if health factor would drop below 1.0
     *   5. Record debt, transfer tokens to user
     *
     * @param user    The borrower (msg.sender in LendingPool)
     * @param amount  Amount of borrow token to lend (USDC units)
     */
    function borrow(
        address user,
        uint256 amount
    ) external onlyLendingPool nonReentrant {
        // CHECK
        if (amount == 0) revert BorrowEngine__ZeroAmount();

        // Accrue interest before any state change
        _accrueInterest();

        // Ensure protocol has enough USDC to lend
        uint256 available = s_borrowToken.balanceOf(address(this));
        if (amount > available) {
            revert BorrowEngine__InsufficientLiquidity(amount, available);
        }

        // Calculate what the user's total debt would be after this borrow
        uint256 currentDebt = _getDebtWithInterest(user);
        uint256 newTotalDebt = currentDebt + amount;

        // Check health factor with the new debt.
        // Borrow guard enforces the 150% collateral ratio, which maps to a
        // stricter HF floor than the 1.0 liquidation threshold:
        //   minBorrowHf = COLLATERAL_RATIO * LIQUIDATION_THRESHOLD / (DENOM^2) * 1e18 = 1.2e18
        uint256 hf = _calculateHealthFactor(user, newTotalDebt);
        uint256 minBorrowHf = LendingConstants.COLLATERAL_RATIO
            * LendingConstants.LIQUIDATION_THRESHOLD
            * LendingConstants.PRECISION
            / (LendingConstants.COLLATERAL_RATIO_DENOMINATOR
                * LendingConstants.LIQUIDATION_THRESHOLD_DENOMINATOR);
        if (hf < minBorrowHf) {
            revert BorrowEngine__HealthFactorTooLow(hf);
        }

        // EFFECT — update debt tracking
        // Store principal normalised by current index so future interest is correct
        s_userDebt[user] = newTotalDebt;
        s_userBorrowIndex[user] = s_borrowIndex;

        emit Borrowed(user, amount);

        // INTERACT — send USDC to user
        s_borrowToken.safeTransfer(user, amount);
    }

    /**
     * @notice Accepts repayment of `amount` borrow tokens from `user`.
     *
     * Flow:
     *   1. Accrue interest globally
     *   2. Calculate current debt including interest
     *   3. Cap repayment at total debt (prevent overpayment)
     *   4. Reduce stored debt, accept token transfer
     *
     * @param user    The borrower repaying
     * @param amount  Amount to repay — capped at total debt if too large
     */
    function repay(
        address user,
        uint256 amount
    ) external onlyLendingPool nonReentrant {
        // CHECK
        if (amount == 0) revert BorrowEngine__ZeroAmount();

        _accrueInterest();

        uint256 totalDebt = _getDebtWithInterest(user);

        // Cap repayment — cannot repay more than owed
        uint256 actualRepay = amount > totalDebt ? totalDebt : amount;

        uint256 remaining = totalDebt - actualRepay;

        // EFFECT
        s_userDebt[user] = remaining;
        if (remaining == 0) {
            // Fully repaid — reset borrow index for clean slate
            s_userBorrowIndex[user] = 0;
        } else {
            // Partially repaid — update index to current
            s_userBorrowIndex[user] = s_borrowIndex;
        }

        emit Repaid(user, actualRepay, remaining);

        // INTERACT
        s_borrowToken.safeTransferFrom(user, address(this), actualRepay);
    }

   /**
 * @notice Repays debt on behalf of a borrower — used by LiquidationEngine only.
 * @param borrower The user whose debt is being repaid
 * @param amount   USDC amount to repay
 */
function repayOnBehalf(
    address borrower,
    uint256 amount
) external onlyLendingPool nonReentrant {
    if (amount == 0) revert BorrowEngine__ZeroAmount();

    _accrueInterest();

    uint256 totalDebt = _getDebtWithInterest(borrower);
    uint256 actualRepay = amount > totalDebt ? totalDebt : amount;
    uint256 remaining = totalDebt - actualRepay;

    s_userDebt[borrower] = remaining;
    s_userBorrowIndex[borrower] = remaining == 0 ? 0 : s_borrowIndex;

    emit Repaid(borrower, actualRepay, remaining);

    // Pull USDC from LiquidationEngine (which already holds it)
    s_borrowToken.safeTransferFrom(msg.sender, address(this), actualRepay);
}

    // ─── Owner functions ──────────────────────────────────────────

    /**
     * @notice Allows owner to deposit USDC liquidity into the protocol.
     * @param amount Amount of USDC to deposit
     */
    function depositLiquidity(uint256 amount) external onlyOwner {
        if (amount == 0) revert BorrowEngine__ZeroAmount();
        s_borrowToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Updates the annual borrow rate. Takes effect immediately.
     * @param newApr New APR in 1e18 precision (10% = 1e17)
     */
    function setBorrowRate(uint256 newApr) external onlyOwner {
        // Accrue with old rate first before switching
        _accrueInterest();
        s_borrowRatePerSecond = newApr / SECONDS_PER_YEAR;
        emit BorrowRateUpdated(s_borrowRatePerSecond);
    }

    // ─── External view ────────────────────────────────────────────

    /**
     * @notice Returns user's current debt including accrued interest.
     * @param user The borrower address
     * @return Total debt in borrow token units
     */
    function getUserDebt(address user) external view returns (uint256) {
        return _getDebtWithInterest(user);
    }

    /**
     * @notice Returns the user's health factor.
     *         >= 1e18 = safe. < 1e18 = liquidatable.
     * @param user The borrower address
     */
    function getHealthFactor(address user) external view returns (uint256) {
        uint256 debt = _getDebtWithInterest(user);
        return _calculateHealthFactor(user, debt);
    }

    /**
     * @notice Returns whether a position can be liquidated.
     * @param user The borrower address
     */
    function isLiquidatable(address user) external view returns (bool) {
        uint256 debt = _getDebtWithInterest(user);
        if (debt == 0) return false;
        uint256 hf = _calculateHealthFactor(user, debt);
        return hf < LendingConstants.MIN_HEALTH_FACTOR;
    }

    /// @notice Returns current global borrow index (1e18 = 1.0)
    function getBorrowIndex() external view returns (uint256) {
        return s_borrowIndex;
    }

    /// @notice Returns current annual borrow rate in 1e18 precision
    function getBorrowRate() external view returns (uint256) {
        return s_borrowRatePerSecond * SECONDS_PER_YEAR;
    }

    /// @notice Returns available USDC liquidity in the protocol
    function getAvailableLiquidity() external view returns (uint256) {
        return s_borrowToken.balanceOf(address(this));
    }

    /// @notice Returns the borrow token address (USDC)
    function getBorrowToken() external view returns (address) {
        return address(s_borrowToken);
    }

    // ─── Internal ─────────────────────────────────────────────────

    /**
     * @notice Updates the global borrow index for elapsed time.
     *
     * Uses simple interest approximation per second:
     *   newIndex = oldIndex × (1 + ratePerSecond × elapsedSeconds)
     *
     * Why not compound interest?
     *   Compound interest requires exponentiation which is expensive on-chain.
     *   Simple interest per-second is accurate enough for short periods
     *   and is the standard approach for EVM lending protocols.
     *
     * Called at the start of every borrow and repay to keep index current.
     */
    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - s_lastUpdateTimestamp;

        // No time has passed — nothing to accrue
        if (elapsed == 0) return;

        // interest = oldIndex × ratePerSecond × elapsed
        uint256 interestFactor = s_borrowRatePerSecond * elapsed;

        // newIndex = oldIndex + (oldIndex × interestFactor / PRECISION)
        uint256 indexIncrease = (s_borrowIndex * interestFactor)
            / LendingConstants.PRECISION;

        s_borrowIndex += indexIncrease;
        s_lastUpdateTimestamp = block.timestamp;

        emit IndexUpdated(s_borrowIndex, block.timestamp);
    }

    /**
     * @notice Calculates a user's debt scaled by interest accrued since their last action.
     *
     * Formula: debt = storedDebt × (currentIndex / userIndex)
     *
     * If the user has no debt or no recorded index, returns 0.
     */
    function _getDebtWithInterest(
        address user
    ) internal view returns (uint256) {
        uint256 principal = s_userDebt[user];
        if (principal == 0) return 0;

        uint256 userIndex = s_userBorrowIndex[user];
        if (userIndex == 0) return 0;

        // Compute the virtual current index including time elapsed since the last
        // on-chain update — necessary because view calls don't trigger _accrueInterest()
        uint256 currentIndex = s_borrowIndex;
        uint256 elapsed = block.timestamp - s_lastUpdateTimestamp;
        if (elapsed > 0) {
            uint256 interestFactor = s_borrowRatePerSecond * elapsed;
            currentIndex += (s_borrowIndex * interestFactor) / LendingConstants.PRECISION;
        }

        return (principal * currentIndex) / userIndex;
    }

    /**
     * @notice Calculates health factor given a user's collateral and a debt amount.
     *
     * Formula:
     *   adjustedCollateral = collateralUSD × LIQUIDATION_THRESHOLD / 100
     *   healthFactor = adjustedCollateral × PRECISION / totalDebt
     *
     * Returns type(uint256).max if user has no debt (infinitely healthy).
     *
     * @param user      The borrower
     * @param totalDebt The debt to check against (can be hypothetical)
     */
    function _calculateHealthFactor(
        address user,
        uint256 totalDebt
    ) internal view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;

        uint256 collateralUsd = s_collateralManager.getCollateralValueUsd(user);
        if (collateralUsd == 0) return 0;

        // Apply liquidation threshold: only 80% of collateral counts toward safety
        uint256 adjustedCollateral = (collateralUsd
            * LendingConstants.LIQUIDATION_THRESHOLD)
            / LendingConstants.LIQUIDATION_THRESHOLD_DENOMINATOR;

        // collateralUsd is 18-decimal; totalDebt is USDC (6-decimal) — scale up to match
        uint256 debtNormalized = totalDebt * 1e12;

        // Health factor in 1e18 precision
        // > 1e18 = safe, < 1e18 = liquidatable
        return (adjustedCollateral * LendingConstants.PRECISION) / debtNormalized;
    }
    /// @dev Only owner can authorise upgrading to a new implementation.
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
{}
}
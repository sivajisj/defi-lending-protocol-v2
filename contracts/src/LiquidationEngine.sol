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
import {BorrowEngine} from "./BorrowEngine.sol";
import {PriceOracle} from "./libraries/PriceOracle.sol";
import {LendingConstants} from "./libraries/LendingConstants.sol";

/**
 * @title LiquidationEngine
 * @notice Allows anyone to liquidate undercollateralised positions.
 *         Liquidator repays debt → receives collateral at a 10% discount.
 *
 * @dev Liquidation is permissionless — any address can call liquidate().
 *      This is intentional. The more liquidators competing, the faster
 *      underwater positions get closed, keeping the protocol solvent.
 *
 *      Only LendingPool can call liquidate() to ensure all access
 *      control and accounting goes through the central entry point.
 */
contract LiquidationEngine is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────

    CollateralManager private s_collateralManager;
    BorrowEngine      private s_borrowEngine;
    PriceOracle       private s_oracle;
    IERC20            private s_borrowToken; // USDC

    address private s_lendingPool;

    // ─── Events ───────────────────────────────────────────────────

    /**
     * @notice Emitted on every successful liquidation.
     * @param liquidator      Address that performed the liquidation
     * @param borrower        Address whose position was liquidated
     * @param debtRepaid      USDC amount repaid by liquidator
     * @param collateralToken Token seized from borrower
     * @param collateralSeized Amount of collateral transferred to liquidator
     */
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtRepaid,
        address collateralToken,
        uint256 collateralSeized
    );

    // ─── Errors ───────────────────────────────────────────────────

    error LiquidationEngine__NotLendingPool(address caller);
    error LiquidationEngine__ZeroAddress();
    error LiquidationEngine__ZeroAmount();
    error LiquidationEngine__LendingPoolAlreadySet();
    /// @dev Position is healthy — cannot liquidate a safe position
    error LiquidationEngine__PositionNotLiquidatable(
        address borrower,
        uint256 healthFactor
    );
    /// @dev Liquidator tried to repay more than the borrower owes
    error LiquidationEngine__DebtRepayTooHigh(
        uint256 requested,
        uint256 totalDebt
    );
    /// @dev Borrower has no collateral in the requested token
    error LiquidationEngine__NoCollateralInToken(
        address borrower,
        address token
    );

    // ─── Modifier ─────────────────────────────────────────────────

    modifier onlyLendingPool() {
        if (msg.sender != s_lendingPool) {
            revert LiquidationEngine__NotLendingPool(msg.sender);
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
     * @notice Sets up the liquidation engine with all protocol dependencies.
     * @param collateralManager  For reading and adjusting collateral balances
     * @param borrowEngine       For reading and reducing debt
     * @param oracle             For pricing collateral in USD
     * @param borrowToken        USDC — what liquidators repay with
     * @param admin              Protocol owner
     */
    function initialize(
        address collateralManager,
        address borrowEngine,
        address oracle,
        address borrowToken,
        address admin
    ) external initializer {
        if (
            collateralManager == address(0) ||
            borrowEngine      == address(0) ||
            oracle            == address(0) ||
            borrowToken       == address(0) ||
            admin             == address(0)
        ) revert LiquidationEngine__ZeroAddress();

        __Ownable_init(admin);

        s_collateralManager = CollateralManager(collateralManager);
        s_borrowEngine      = BorrowEngine(borrowEngine);
        s_oracle            = PriceOracle(oracle);
        s_borrowToken       = IERC20(borrowToken);
    }

    // ─── Setup ────────────────────────────────────────────────────

    function setLendingPool(address lendingPool) external onlyOwner {
        if (s_lendingPool != address(0)) {
            revert LiquidationEngine__LendingPoolAlreadySet();
        }
        if (lendingPool == address(0)) revert LiquidationEngine__ZeroAddress();
        s_lendingPool = lendingPool;
    }

    // ─── Core liquidation ─────────────────────────────────────────

    /**
     * @notice Liquidates an undercollateralised position.
     *
     * Flow:
     *   1. Verify position is liquidatable (health factor < 1.0)
     *   2. Cap debtToRepay at total debt
     *   3. Calculate collateral to seize including 10% bonus
     *   4. Pull USDC from liquidator → repay via BorrowEngine
     *   5. Transfer seized collateral from CollateralManager to liquidator
     *   6. Verify borrower's health factor improved
     *
     * @param liquidator     Address performing the liquidation (msg.sender in LendingPool)
     * @param borrower       Address of the undercollateralised user
     * @param collateralToken Which of the borrower's collateral tokens to seize
     * @param debtToRepay    USDC amount the liquidator will repay
     */
    function liquidate(
        address liquidator,
        address borrower,
        address collateralToken,
        uint256 debtToRepay
    ) external onlyLendingPool nonReentrant returns (uint256 collateralToSeize) {
        // ── CHECK 1: inputs ───────────────────────────────────────
        if (debtToRepay == 0) revert LiquidationEngine__ZeroAmount();
        if (
            borrower       == address(0) ||
            collateralToken == address(0) ||
            liquidator      == address(0)
        ) revert LiquidationEngine__ZeroAddress();

        // ── CHECK 2: position must be liquidatable ────────────────
        uint256 healthFactor = s_borrowEngine.getHealthFactor(borrower);
        if (healthFactor >= LendingConstants.MIN_HEALTH_FACTOR) {
            revert LiquidationEngine__PositionNotLiquidatable(
                borrower,
                healthFactor
            );
        }

        // ── CHECK 3: cannot repay more than borrower owes ─────────
        uint256 totalDebt = s_borrowEngine.getUserDebt(borrower);
        if (debtToRepay > totalDebt) {
            revert LiquidationEngine__DebtRepayTooHigh(debtToRepay, totalDebt);
        }

        // ── CHECK 4: borrower must have collateral in this token ──
        uint256 borrowerCollateral = s_collateralManager.getCollateralBalance(
            borrower,
            collateralToken
        );
        if (borrowerCollateral == 0) {
            revert LiquidationEngine__NoCollateralInToken(
                borrower,
                collateralToken
            );
        }

        // ── CALCULATE collateral to seize ─────────────────────────
        collateralToSeize = _calculateCollateralToSeize(collateralToken, debtToRepay);

        if (collateralToSeize > borrowerCollateral) {
            collateralToSeize = borrowerCollateral;
        }

        // ── EFFECT: pull USDC from liquidator, forward to LendingPool ─
        // LendingPool (msg.sender) will call repayOnBehalf and seizeCollateral
        s_borrowToken.safeTransferFrom(liquidator, msg.sender, debtToRepay);

        emit Liquidated(
            liquidator,
            borrower,
            debtToRepay,
            collateralToken,
            collateralToSeize
        );
    }

    // ─── View ─────────────────────────────────────────────────────

    /**
     * @notice Calculates how much collateral a liquidator would receive
     *         for repaying a given USDC debt amount.
     *
     * @param collateralToken  The token being seized
     * @param debtRepaidUsd    USDC amount being repaid (6 decimals)
     * @return collateralAmount Raw token amount the liquidator receives
     */
    function previewLiquidation(
        address collateralToken,
        uint256 debtRepaidUsd
    ) external view returns (uint256 collateralAmount) {
        return _calculateCollateralToSeize(collateralToken, debtRepaidUsd);
    }

    /**
     * @notice Returns whether a position can currently be liquidated.
     * @param borrower The address to check
     */
    function isLiquidatable(address borrower) external view returns (bool) {
        return s_borrowEngine.isLiquidatable(borrower);
    }

    // ─── Internal ─────────────────────────────────────────────────

    /**
     * @notice Calculates collateral amount to seize including the 10% bonus.
     *
     * Steps:
     *   1. Add liquidation bonus to debt amount
     *      bonusAdjustedDebt = debtToRepay × (100 + 10) / 100
     *   2. Get collateral USD price from oracle
     *   3. Convert bonusAdjustedDebt (USDC, 6 dec) to collateral token amount
     *
     * Formula:
     *   collateralSeized = (debtRepaid × 110/100) / collateralPricePerUnit
     *
     * Example — liquidator repays $3,500 USDC, ETH = $600:
     *   bonusDebt     = 3500 × 1.10 = $3,850
     *   ETH per $1    = 1e18 / 600e18 = 0.001666... WETH
     *   WETHSeized    = 3850 × (1e18 / 600e18) = 6.416 WETH
     *
     * @param collateralToken  The collateral token being seized
     * @param debtToRepay      USDC amount repaid (in USDC units, 6 decimals)
     * @return collateralSeized Amount of collateral token to transfer
     */
    function _calculateCollateralToSeize(
        address collateralToken,
        uint256 debtToRepay
    ) internal view returns (uint256 collateralSeized) {
        // Step 1 — apply liquidation bonus to debt
        // debtToRepay is in USDC units (6 decimals)
        // Treat it as USD value for the calculation
        uint256 bonusAdjustedDebt = debtToRepay
            + (debtToRepay * LendingConstants.LIQUIDATION_BONUS)
            / LendingConstants.LIQUIDATION_BONUS_DENOMINATOR;
        // bonusAdjustedDebt is still in USDC units (6 decimals)

        // Step 2 — get price of 1 full token unit in USD (18 decimal precision)
        // We ask: what is 1 full token (1e tokenDecimals) worth in USD?
        // This gives us USD per token in 18-decimal precision
        uint8 tokenDecimals = _getDecimals(collateralToken);
        uint256 oneToken = 10 ** uint256(tokenDecimals);
        uint256 pricePerToken = s_oracle.getUsdValue(collateralToken, oneToken);
        // pricePerToken = e.g. 2000e18 for WETH at $2000

        // Step 3 — convert bonusAdjustedDebt (6 decimal USDC) to collateral amount
        // We need to express bonusAdjustedDebt in 18-decimal USD first
        // then divide by price per token
        //
        // bonusAdjustedDebt in 18-dec = bonusAdjustedDebt × 1e12
        // (USDC has 6 decimals, we need 18, so multiply by 1e12)
        //
        // collateralSeized = (bonusAdjustedDebt × 1e12 × 1e18) / pricePerToken
        // The second 1e18 compensates for the division
        collateralSeized = (bonusAdjustedDebt * 1e12 * LendingConstants.PRECISION)
            / pricePerToken;
    }

    /**
     * @notice Fetches token decimals via low-level staticcall.
     *         Falls back to 18 if the call fails.
     */
    function _getDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && data.length > 0) return abi.decode(data, (uint8));
        return 18;
    }

    /// @dev Only owner can authorise upgrading to a new implementation.
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
{}
}
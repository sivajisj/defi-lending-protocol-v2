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
    import {LiquidationEngine} from "./LiquidationEngine.sol";
import {CollateralManager} from "./CollateralManager.sol";
import {BorrowEngine} from "./BorrowEngine.sol";
import {LendingConstants} from "./libraries/LendingConstants.sol";

/**
 * @title LendingPool
 * @notice Single entry point for all user-facing actions.
 *         Routes calls to CollateralManager and BorrowEngine.
 *         Enforces health factor on every withdrawal.
 *
 * @dev Users call only these four functions:
 *      depositCollateral → withdrawCollateral → borrowUSDC → repayUSDC
 *
 *      Health factor is checked after every action that could reduce it.
 *      If health factor drops below MIN_HEALTH_FACTOR the transaction reverts.
 */
contract LendingPool is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    // ─── State ────────────────────────────────────────────────────

    CollateralManager private s_collateralManager;
    BorrowEngine      private s_borrowEngine;
    LiquidationEngine private s_liquidationEngine;

    /// @dev Tracks which tokens are accepted as collateral
    mapping(address token => bool allowed) private s_allowedCollateral;

    // ─── Events ───────────────────────────────────────────────────

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event CollateralWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event CollateralTokenAdded(address indexed token);

    // ─── Errors ───────────────────────────────────────────────────

    error LendingPool__ZeroAmount();
    error LendingPool__ZeroAddress();
    error LendingPool__TokenNotAllowed(address token);
    error LendingPool__HealthFactorTooLow(uint256 healthFactor);

    // ─── Constructor ──────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ──────────────────────────────────────────────

    /**
     * @notice Wires all internal contracts together.
     * @param collateralManager  Deployed CollateralManager address
     * @param borrowEngine       Deployed BorrowEngine address
     * @param allowedTokens      Tokens accepted as collateral (WETH, WBTC)
     * @param admin              Protocol owner
     */
    function initialize(
        address collateralManager,
        address borrowEngine,
        address liquidationEngine,
        address[] calldata allowedTokens,
        address admin

    ) external initializer {
        if (
    collateralManager == address(0) ||
    borrowEngine      == address(0) ||
    liquidationEngine == address(0) ||
    admin             == address(0)
) revert LendingPool__ZeroAddress();

        __Ownable_init(admin);
       

        s_collateralManager = CollateralManager(collateralManager);
        s_borrowEngine      = BorrowEngine(borrowEngine);

        uint256 len = allowedTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            s_allowedCollateral[allowedTokens[i]] = true;
            emit CollateralTokenAdded(allowedTokens[i]);
        }
        if (liquidationEngine == address(0)) revert LendingPool__ZeroAddress();
    s_liquidationEngine = LiquidationEngine(liquidationEngine);
    }

    // ─── User-facing functions ────────────────────────────────────

    /**
     * @notice Deposits ERC20 collateral on behalf of msg.sender.
     *
     * User must approve this contract before calling.
     * Approval amount: at least `amount` of `token`.
     *
     * @param token  Collateral token address (WETH or WBTC)
     * @param amount Amount in token's native decimals
     */
    function depositCollateral(
        address token,
        uint256 amount
    ) external nonReentrant {
        // CHECK
        if (amount == 0) revert LendingPool__ZeroAmount();
        if (!s_allowedCollateral[token]) {
            revert LendingPool__TokenNotAllowed(token);
        }

        emit CollateralDeposited(msg.sender, token, amount);

        // INTERACT — CollateralManager pulls tokens from user
        s_collateralManager.depositCollateral(msg.sender, token, amount);
    }

    /**
     * @notice Withdraws collateral back to msg.sender.
     *         Reverts if withdrawal would make health factor unsafe.
     *
     * @param token  Collateral token to withdraw
     * @param amount Amount to withdraw in token's native decimals
     */
    function withdrawCollateral(
        address token,
        uint256 amount
    ) external nonReentrant {
        // CHECK
        if (amount == 0) revert LendingPool__ZeroAmount();
        if (!s_allowedCollateral[token]) {
            revert LendingPool__TokenNotAllowed(token);
        }

        // INTERACT — withdraw first, then check health factor
        // This is safe because CollateralManager has its own balance check
        // and we revert the whole tx if health factor fails after
        s_collateralManager.withdrawCollateral(msg.sender, token, amount);

        emit CollateralWithdrawn(msg.sender, token, amount);

        // HEALTH CHECK — revert entire tx if position is now unsafe
        _revertIfHealthFactorBroken(msg.sender);
    }

    /**
     * @notice Borrows USDC against deposited collateral.
     *         BorrowEngine checks health factor internally before lending.
     *
     * @param amount USDC amount to borrow (6 decimals — 1000 USDC = 1000e6)
     */
    function borrowUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert LendingPool__ZeroAmount();

        // BorrowEngine handles health factor check internally
        s_borrowEngine.borrow(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    /**
     * @notice Repays USDC debt for msg.sender.
     *         User must approve BorrowEngine to spend their USDC before calling.
     *
     * @param amount USDC amount to repay — capped at total debt if too large
     */
    function repayUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert LendingPool__ZeroAmount();

        s_borrowEngine.repay(msg.sender, amount);

        emit Repaid(msg.sender, amount);
    }

    // ─── Owner functions ──────────────────────────────────────────

    /**
     * @notice Adds a new accepted collateral token.
     * @param token Token address to whitelist
     */
    function addCollateralToken(address token) external onlyOwner {
        if (token == address(0)) revert LendingPool__ZeroAddress();
        s_allowedCollateral[token] = true;
        emit CollateralTokenAdded(token);
    }

    // ─── View functions ───────────────────────────────────────────

    /**
     * @notice Returns the user's full position summary in one call.
     * @param user The address to query
     * @return collateralUsd  Total collateral value in USD (18 decimals)
     * @return debtUsd        Total USDC debt (6 decimals)
     * @return healthFactor   Current health factor (1e18 = 1.0)
     * @return liquidatable   Whether the position can be liquidated now
     */
    function getUserPosition(address user)
        external
        view
        returns (
            uint256 collateralUsd,
            uint256 debtUsd,
            uint256 healthFactor,
            bool    liquidatable
        )
    {
        collateralUsd = s_collateralManager.getCollateralValueUsd(user);
        debtUsd       = s_borrowEngine.getUserDebt(user);
        healthFactor  = s_borrowEngine.getHealthFactor(user);
        liquidatable  = s_borrowEngine.isLiquidatable(user);
    }

    /**
     * @notice Returns whether a token is accepted as collateral.
     */
    function isAllowedCollateral(address token) external view returns (bool) {
        return s_allowedCollateral[token];
    }

    /**
     * @notice Returns the CollateralManager address.
     */
    function getCollateralManager() external view returns (address) {
        return address(s_collateralManager);
    }

    /**
     * @notice Returns the BorrowEngine address.
     */
    function getBorrowEngine() external view returns (address) {
        return address(s_borrowEngine);
    }

    // ─── Internal ─────────────────────────────────────────────────

    /**
     * @notice Reverts if the user's health factor is below MIN_HEALTH_FACTOR.
     *         Called after every withdrawal to protect protocol solvency.
     *
     * @param user The user whose position to check
     */
    function _revertIfHealthFactorBroken(address user) internal view {
        uint256 hf = s_borrowEngine.getHealthFactor(user);
        if (hf < LendingConstants.MIN_HEALTH_FACTOR) {
            revert LendingPool__HealthFactorTooLow(hf);
        }
    }

    // ─── UUPS ─────────────────────────────────────────────────────

    /// @dev Only owner can authorise an upgrade to a new implementation.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /**
 * @notice Liquidates an undercollateralised position.
 *         Anyone can call this — liquidators earn a 10% bonus.
 *
 * Before calling, liquidator must:
 *   1. Approve LiquidationEngine to spend their USDC
 *   2. Have enough USDC to cover debtToRepay
 *
 * @param borrower        The underwater position to liquidate
 * @param collateralToken Which collateral token to seize
 * @param debtToRepay     USDC amount to repay on borrower's behalf
 */
function liquidate(
    address borrower,
    address collateralToken,
    uint256 debtToRepay
) external nonReentrant {
    if (debtToRepay == 0) revert LendingPool__ZeroAmount();

    // LiquidationEngine validates the position, calculates collateral to seize,
    // and transfers USDC from the liquidator into this contract.
    uint256 collateralToSeize = s_liquidationEngine.liquidate(
        msg.sender,
        borrower,
        collateralToken,
        debtToRepay
    );

    // Approve BorrowEngine to pull the USDC that now sits in this contract,
    // then repay the borrower's debt on their behalf.
    IERC20(s_borrowEngine.getBorrowToken()).approve(address(s_borrowEngine), debtToRepay);
    s_borrowEngine.repayOnBehalf(borrower, debtToRepay);

    // Transfer the seized collateral from CollateralManager to the liquidator.
    s_collateralManager.seizeCollateral(borrower, msg.sender, collateralToken, collateralToSeize);
}

/// @notice Returns the LiquidationEngine address
function getLiquidationEngine() external view returns (address) {
    return address(s_liquidationEngine);
}
}
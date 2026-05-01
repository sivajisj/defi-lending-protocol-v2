// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PriceOracle} from "./libraries/PriceOracle.sol";
import {LendingConstants} from "./libraries/LendingConstants.sol";



/**
 * @title CollateralManager
 * @author Sivaji
 * @notice Manages all collateral deposits and withdrawals for the lending protocol.
 *         Tracks per-user, per-token balances and calculates total USD collateral value.
 *
 * @dev ARCHITECTURE DECISION — why is this a separate contract from LendingPool?
 *
 *      
 *
 *      WHO CAN CALL THIS CONTRACT?
 *      Only LendingPool can call depositCollateral() and withdrawCollateral().
 *      This is enforced by the onlyLendingPool modifier.
 *      Users NEVER interact with CollateralManager directly — only through LendingPool.
 *      This prevents a user from bypassing LendingPool's health factor checks.
 *
 * ─────────────────────────────────────────────────────────────────
 * CEI PATTERN — applied throughout this contract
 * ─────────────────────────────────────────────────────────────────
 *
 *  Every function that transfers tokens follows this exact order:
 *
 *  CHECKS:   validate inputs, check permissions, verify state is valid
 *  EFFECTS:  update all state variables (balances, totals)
 *  INTERACT: make the external token transfer LAST
 *
 *  Why? If we transferred tokens BEFORE updating state, a malicious
 *  ERC20 token could call back into this contract during transfer
 *  (reentrancy attack) and see the old, un-updated state.
 *  Example: user appears to have 0 collateral → they withdraw again → drain vault.
 *
 *  We also add ReentrancyGuard as a belt-and-suspenders defence.
 *  CEI prevents the attack logically; ReentrancyGuard prevents it mechanically.
 *
 * ─────────────────────────────────────────────────────────────────
 * SafeERC20 — why we use it instead of raw transfer()
 * ─────────────────────────────────────────────────────────────────
 *
 *  The ERC20 standard says transfer() should return bool.
 *  Some tokens (USDT, BNB) don't return anything — they just revert on failure.
 *  If you call token.transfer() on USDT and check the return value, you get
 *  a compiler error because there's no bool to check.
 *
 *  SafeERC20.safeTransfer() handles both cases:
 *  - If the token returns bool: checks it is true
 *  - If the token returns nothing: checks the call didn't revert
 *  Always use SafeERC20 in production — raw transfer() will silently fail
 *  on some tokens and you will lose user funds.
 */
contract CollateralManager is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{

    using SafeERC20 for IERC20;
    /**
     * @dev The price oracle — used to calculate USD value of collateral
     *      Set once during initialize(), never changed (immutable-like behaviour)
     */
    PriceOracle private s_oracle;

        /**
     * @dev The LendingPool address — the ONLY address allowed to call
     *      depositCollateral() and withdrawCollateral().
     *      Set once during initialize() by the LendingPool itself.
     */
    address private s_lendingPool;

    /**
     * @dev Core accounting: user → token → amount deposited
     *
     *      Example state after two deposits:
     *      s_collateralDeposited[alice][WETH] = 2e18   (2 WETH)
     *      s_collateralDeposited[alice][WBTC] = 5e7    (0.5 WBTC)
     *      s_collateralDeposited[bob][WETH]   = 1e18   (1 WETH)
     *
     *      Using nested mappings instead of arrays because:
     *      - O(1) lookup: get alice's WETH balance instantly
     *      - No iteration needed: we don't need to loop over all users
     *      - Gas efficient: mappings have no length to maintain
     */
    mapping(address user => mapping(address token =>uint256 amount)) private s_collateralDeposited;
    
        /**
     * @dev Tracks all tokens a user has ever deposited
     *      Used when calculating total collateral USD value —
     *      we need to know which tokens to price.
     *
     *      Why not use the mapping keys? Mappings in Solidity cannot be iterated.
     *      So we maintain a parallel array of tokens per user.
     *
     *      Example: alice deposited WETH then WBTC
     *      s_userCollateralTokens[alice] = [WETH, WBTC]
     */
    mapping(address user =>address[] tokens) private s_userCollateralTokens;

      /**
     * @dev Prevents duplicate entries in s_userCollateralTokens
     *      Before pushing a token into the array, check this mapping first.
     *      s_hasDeposited[alice][WETH] = true (after first WETH deposit)
     */
    mapping(address user =>mapping (address token => bool deposited)) private s_hasDeposited;

    // EVENTS
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event CollateralSeized(address indexed borrower, address indexed liquidator, address indexed token, uint256 amount);

    //ERRORS
    error CollateralManager__ZeroAmount();
    error CollateralManager__NotLendingPool();
    error CollateralManager__InsufficientCollateral(
        address user,
        address token,
        uint256 requested,
        uint256 available
    );

    error CollateralManager__ZeroAddress();
    error CollateralManager__LendingPoolAlreadySet();

    // MODIFIERS
    modifier onlyLendingPool() {
        if (msg.sender != s_lendingPool) {
            revert CollateralManager__NotLendingPool();
        }
        _;
    }

    constructor() {
        // Disable initializers on the implementation contract
        _disableInitializers();
    }

     // INITIALIZER
    /**
     * @notice Initialises the CollateralManager with its dependencies
     * @param oracle  The deployed PriceOracle address
     * @param admin   The protocol admin address (owner)
     *
     * @dev LendingPool address is NOT set here — it is set separately via
     *      setLendingPool() after both contracts are deployed.
     *      This avoids a circular dependency: LendingPool needs CollateralManager,
     *      CollateralManager needs LendingPool.
     *      Solution: deploy both, then wire them together.
     */
    function initialize(
        address oracle ,
        address admin
    ) external initializer {
        if (oracle == address(0) || admin == address(0)) {
            revert CollateralManager__ZeroAddress();
        }
        s_oracle = PriceOracle(oracle);
        __Ownable_init(admin);
    }

    // SETUP FUNCTIONS

    /**
     * @notice Sets the authorised LendingPool address
     * @param lendingPool The LendingPool contract address
     *
     * @dev Called once after both contracts are deployed.
     *      Cannot be called again once set — prevents an admin from
     *      redirecting calls to a malicious contract later.
     *
     *      In production this would be called by the deployment script
     *      immediately after deploying LendingPool.
     */
    function setLendingPool(address lendingPool) external onlyOwner {
        if (s_lendingPool != address(0)) {
            revert CollateralManager__LendingPoolAlreadySet();
        }
        if (lendingPool == address(0)) {
            revert CollateralManager__ZeroAddress();
        }
        s_lendingPool = lendingPool;
    }

    // EXTERNAL FUNCTIONS — called by LendingPool only

    /**
     * @notice Records a collateral deposit and transfers tokens into the vault
     * @param user   The user depositing collateral (msg.sender in LendingPool)
     * @param token  The ERC20 token being deposited
     * @param amount The amount to deposit (in token's native decimals)
     */

    function depositCollateral(
        address user,
        address token,
        uint256 amount
    ) external onlyLendingPool nonReentrant {
        if (amount == 0) {
            revert CollateralManager__ZeroAmount();
        }

        // CHECKS: none needed — LendingPool already checks everything

        // EFFECTS: update accounting before transfer (CEI pattern)
        s_collateralDeposited[user][token] += amount;

        // If user hasn't deposited this token before, add to their token list
        if (!s_hasDeposited[user][token]) {
            s_userCollateralTokens[user].push(token);
            s_hasDeposited[user][token] = true;
        }

        // INTERACT: transfer tokens into the vault
        IERC20(token).safeTransferFrom(user, address(this), amount);

        emit CollateralDeposited(user, token, amount);
    }

     /**
     * @notice Records a collateral withdrawal and transfers tokens back to the user
     * @param user   The user withdrawing collateral (msg.sender in LendingPool)
     * @param token  The ERC20 token being withdrawn
     * @param amount The amount to withdraw (in token's native decimals)
     */
     function withdrawCollateral(
        address user,
        address token,
        uint256 amount
     )external onlyLendingPool nonReentrant{
        if (amount ==0 ) revert CollateralManager__ZeroAmount();

        uint256 currentBalance = s_collateralDeposited[user][token];
        if (amount > currentBalance) {
            revert CollateralManager__InsufficientCollateral(
                user,
                token,
                amount,
                currentBalance
            );
     }

    s_collateralDeposited[user][token] -= amount;
    emit CollateralWithdrawn(user, token, amount);

    //INTRERACT: transfer tokens back to the user
    IERC20(token).safeTransfer(user, amount);
     }

/**
 * @notice Transfers collateral from borrower to liquidator — used by LiquidationEngine only.
 * @param borrower    The user being liquidated
 * @param liquidator  The address receiving the seized collateral
 * @param token       The collateral token being seized
 * @param amount      Amount to seize in token's native decimals
 */
function seizeCollateral(
    address borrower,
    address liquidator,
    address token,
    uint256 amount
) external onlyLendingPool nonReentrant {
    if (amount == 0) revert CollateralManager__ZeroAmount();

    uint256 balance = s_collateralDeposited[borrower][token];
    if (amount > balance) {
        revert CollateralManager__InsufficientCollateral(
            borrower, token, amount, balance
        );
    }

    // EFFECT — reduce borrower's recorded balance
    s_collateralDeposited[borrower][token] -= amount;

    emit CollateralWithdrawn(borrower, token, amount);

    // INTERACT — transfer token to liquidator
    IERC20(token).safeTransfer(liquidator, amount);
}

     function getCollateralValueUsd(address user) external view returns(uint256 totalUsdValue) {
        address[] memory userTokens = s_userCollateralTokens[user];
        uint256 length = userTokens.length;

        for (uint256 i = 0; i < length; i++) {
            address token = userTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount == 0) {
                continue; // Skip tokens with zero balance
            }
            uint256 tokenValueUsd = s_oracle.getUsdValue(token, amount);
            totalUsdValue += tokenValueUsd;

        }
     }

        /**
     * @notice Returns how much of a specific token a user has deposited
     * @param user  The user's address
     * @param token The collateral token address
     * @return The raw token amount (in token's native decimals)
     */
    function getCollateralBalance(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

        /**
     * @notice Returns all tokens a user has deposited as collateral
     * @param user The user's address
     * @return Array of token addresses
     */
    function getUserCollateralTokens(
        address user
    ) external view returns (address[] memory) {
        return s_userCollateralTokens[user];
    }

        /**
     * @notice Returns the address of the PriceOracle this manager uses
     */
    function getOracle() external view returns (address) {
        return address(s_oracle);
    }

        /**
     * @notice Returns the authorised LendingPool address
     */
    function getLendingPool() external view returns (address) {
        return s_lendingPool;
    }

        /// @dev Only owner can authorise upgrading to a new implementation.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}






}
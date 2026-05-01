// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {LendingConstants} from "./LendingConstants.sol";

/**
 * @title PriceOracle
 * @author Sivaji
 * @notice Wraps Chainlink price feeds and exposes a single clean function:
 *         getUsdValue(token, amount) → USD value in 18-decimal precision.
 *
 * @dev This contract sits between the Chainlink feeds and every other
 *      contract in the protocol. Nobody else reads Chainlink directly.
 *
 *      UPGRADEABLE DESIGN (preview of Step 8):
 *      This contract uses the UUPS (Universal Upgradeable Proxy Standard) pattern.
 *      That means:
 *      1. You deploy a Proxy contract (the permanent address users interact with)
 *      2. You deploy PriceOracle as the "implementation" contract
 *      3. The proxy delegates all calls to the implementation
 *      4. To upgrade: deploy a new PriceOracle, tell the proxy to point to it
 *      5. The proxy address never changes — users don't notice the upgrade
 *
 *      Because of UUPS, we CANNOT use a constructor for state initialisation.
 *      A constructor runs on the implementation contract, not the proxy.
 *      So state set in the constructor is invisible through the proxy.
 *      Solution: use an initialize() function marked with the `initializer`
 *      modifier — this runs once, through the proxy, setting state correctly.
 *

 */
contract PriceOracle is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ──────────────────────────────────────────────────────────────
    // STATE VARIABLES
    // ──────────────────────────────────────────────────────────────

    /**
     * @dev Maps each collateral token address → its Chainlink price feed address
     *
     *      In tests:   token → MockV3Aggregator
     *      On Sepolia: token → real Chainlink feed (e.g. 0x694AA1769357215DE4FAC081bf1f309aDC325306)
     *      Same code, different addresses — this is why interfaces matter.
     *
     *      We use `private` so only this contract reads it.
     *      External parties call getUsdValue() instead of reading raw feeds.
     */
    mapping(address token => address priceFeed) private s_priceFeeds;

    /**
     * @dev Tracks which tokens are allowed as collateral
     *      Prevents users from depositing random tokens with no price feed.
     *      Only the owner (protocol admin/multisig in production) can add tokens.
     */
    mapping(address token => bool allowed) private s_allowedCollateral;

    // ──────────────────────────────────────────────────────────────
    // EVENTS
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when a new collateral token is added to the protocol
     * @param token     The ERC20 token address
     * @param priceFeed The Chainlink feed address for this token
     */
    event CollateralAdded(address indexed token, address indexed priceFeed);
    // ERRORS

    /// @dev Token has no price feed registered — cannot use as collateral
    error PriceOracle__TokenNotAllowed(address token);

    /// @dev Chainlink returned a zero or negative price — should never happen
    ///      but we guard against it anyway (edge case on feed failures)
    error PriceOracle__InvalidPrice(int256 price);

    /// @dev Chainlink has not updated the price within FEED_TIMEOUT seconds
    ///      This means the feed may be down or the price may be wildly wrong
    error PriceOracle__StalePrice(address token, uint256 updatedAt);

    /// @dev address(0) passed where a real address is required
    error PriceOracle__ZeroAddress();

    // ──────────────────────────────────────────────────────────────
    // CONSTRUCTOR — disabled for upgradeable contracts
    // ──────────────────────────────────────────────────────────────

    /**
     * @dev _disableInitializers() prevents anyone from calling initialize()
     *      directly on the implementation contract (not through the proxy).
     *
     *      Why does this matter?
     *      If someone calls initialize() on the bare implementation contract,
     *      they become the owner of the implementation.
     *      They could then call upgradeTo() and replace the implementation
     *      with a malicious contract — even though the proxy is safe.
     *      Disabling initializers on the implementation prevents this attack.
     *
     *      This is a known security pattern recommended by OpenZeppelin.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────────────────────
    // INITIALIZER — replaces constructor for upgradeable contracts
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Sets up the oracle with initial collateral tokens and their feeds
     * @param tokens     Array of collateral token addresses (WETH, WBTC, ...)
     * @param priceFeeds Array of Chainlink feed addresses — must match tokens index
     * @param admin      Address that will own this contract (protocol multisig)
     *
     * @dev The `initializer` modifier from OpenZeppelin ensures this function
     *      can only be called ONCE. If called again (e.g. by an attacker),
     *      it reverts. This is equivalent to the constructor's single-run guarantee.
     *
     *      Called by the deployment script (Step 10) after the proxy is created.
     *
     * Example (from deploy script):
     *      address[] memory tokens = [wethAddress, wbtcAddress];
     *      address[] memory feeds  = [ethUsdFeed, btcUsdFeed];
     *      oracle.initialize(tokens, feeds, adminMultisig);
     */
    function initialize(
        address[] calldata tokens,
        address[] calldata priceFeeds,
        address admin
    ) external initializer {
        // Initialize parent contracts — these set up Ownable internals
        // Always call these first before any custom logic
        __Ownable_init(admin);

        if (admin == address(0)) revert PriceOracle__ZeroAddress();

        // Register each token → feed pair
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; ++i) {
            _addCollateral(tokens[i], priceFeeds[i]);
        }
    }

    // ──────────────────────────────────────────────────────────────
    // EXTERNAL FUNCTIONS — called by other protocol contracts
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Registers a new collateral token with its Chainlink price feed
     * @param token     The ERC20 token to allow as collateral
     * @param priceFeed The Chainlink V3 aggregator address for this token/USD pair
     *
     * @dev Only the protocol owner (admin multisig in production) can add tokens.
     *      In production this would go through a timelock + governance vote.
     *      For this protocol we keep it simple with Ownable.
     */
    function addCollateral(address token, address priceFeed) external onlyOwner {
        _addCollateral(token, priceFeed);
    }

    // ──────────────────────────────────────────────────────────────
    // EXTERNAL VIEW FUNCTIONS — read price data
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Returns the USD value of a given token amount in 18-decimal precision
     * @param token  The collateral token address (WETH, WBTC, etc.)
     * @param amount The raw token amount (in the token's own decimals)
     * @return usdValue The USD value scaled to 18 decimals
     *
     * @dev This is the core function every other contract calls.
     *      It handles:
     *      1. Token allowance check
     *      2. Fetching the Chainlink price
     *      3. Staleness check
     *      4. Validity check (positive price)
     *      5. Decimal normalisation (token decimals + feed decimals → 18 decimals)
     *
     * ── DECIMAL NORMALISATION DEEP DIVE ──────────────────────────
     *
     *  The problem: tokens have different decimals, Chainlink has 8 decimals,
     *  we need everything in 18 decimals.
     *
     *  Formula:
     *  usdValue = (price * ADDITIONAL_FEED_PRECISION * amount * PRECISION)
     *             / (PRECISION * (10 ** tokenDecimals))
     *
     *  Simplified:
     *  usdValue = (price18 * amount) / (10 ** tokenDecimals)
     *  where price18 = price * 1e10  (converts 8-decimal price to 18-decimal)
     *
     *  ── EXAMPLE 1: 1 WETH at $2000 ──
     *  token decimals = 18
     *  amount         = 1e18   (1 WETH)
     *  price          = 2000e8 (Chainlink answer)
     *  price18        = 2000e8 * 1e10 = 2000e18
     *  usdValue       = (2000e18 * 1e18) / (10**18)
     *                 = 2000e18 / 1e18
     *                 = 2000e18   ← $2000 in 18-decimal precision ✓
     *
     *  ── EXAMPLE 2: 1 WBTC at $60,000 ──
     *  token decimals = 8
     *  amount         = 1e8    (1 WBTC)
     *  price          = 60000e8
     *  price18        = 60000e8 * 1e10 = 60000e18
     *  usdValue       = (60000e18 * 1e8) / (10**8)
     *                 = (60000e26) / 1e8
     *                 = 60000e18  ← $60,000 in 18-decimal precision ✓
     *
     *  ── EXAMPLE 3: 1000 USDC at $1 each ($1000 total) ──
     *  token decimals = 6
     *  amount         = 1000e6  (1000 USDC)
     *  price          = 1e8     (USDC/USD = $1.00000000)
     *  price18        = 1e8 * 1e10 = 1e18
     *  usdValue       = (1e18 * 1000e6) / (10**6)
     *                 = (1000e24) / 1e6
     *                 = 1000e18  ← $1,000 in 18-decimal precision ✓
     *
     *  The formula works for ANY token decimal count.
     */
    function getUsdValue(
        address token,
        uint256 amount
    ) external view returns (uint256 usdValue) {
        // ── Step 1: Check this token is registered ────────────────
        if (!s_allowedCollateral[token]) {
            revert PriceOracle__TokenNotAllowed(token);
        }

        // ── Step 2: Fetch the Chainlink price ─────────────────────
        // We only need `answer` and `updatedAt` from the 5 return values
        // The other 3 (roundId, startedAt, answeredInRound) are unused here
        AggregatorV3Interface feed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();

        // ── Step 3: Staleness check ───────────────────────────────
        // If the feed was last updated more than FEED_TIMEOUT seconds ago,
        // the price may be dangerously outdated — reject it entirely.
        // This protects the protocol if Chainlink nodes go offline.
        if (block.timestamp - updatedAt > LendingConstants.FEED_TIMEOUT) {
            revert PriceOracle__StalePrice(token, updatedAt);
        }

        // ── Step 4: Validity check ────────────────────────────────
        // Chainlink uses int256 (signed) — negative prices are technically
        // possible (e.g. crude oil went negative in 2020).
        // For our USD collateral feeds, a zero or negative price means
        // something has gone very wrong. Reject it to protect the protocol.
        if (price <= 0) {
            revert PriceOracle__InvalidPrice(price);
        }

        // ── Step 5: Decimal normalisation ─────────────────────────
        // Get how many decimals this token has (18 for WETH, 8 for WBTC, 6 for USDC)
        // We call decimals() on the token itself — no hardcoding
        uint8 tokenDecimals;
        // Using a low-level call because some tokens don't implement decimals()
        // (though all ours do). Low-level call = no revert if function missing.
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (success && data.length > 0) {
            tokenDecimals = abi.decode(data, (uint8));
        } else {
            // Default to 18 if the token doesn't expose decimals()
            tokenDecimals = 18;
        }

        // Convert price from 8 decimals to 18 decimals
        // price is int256 — cast to uint256 (safe because we checked price > 0)
        uint256 price18 = uint256(price) * LendingConstants.ADDITIONAL_FEED_PRECISION;

        // Calculate USD value normalised to 18 decimals
        // Multiply price (18 dec) × amount (token decimals) → divide by token decimals
        // Result always has 18 decimals regardless of input token decimals
        usdValue = (price18 * amount) / (10 ** uint256(tokenDecimals));
    }

    /**
     * @notice Returns the Chainlink feed address for a given token
     * @dev Useful for off-chain scripts and monitoring tools
     */
    function getPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /**
     * @notice Returns whether a token is allowed as collateral
     */
    function isAllowedCollateral(address token) external view returns (bool) {
        return s_allowedCollateral[token];
    }

    /**
     * @notice Returns the raw Chainlink price without any normalisation
     * @dev Useful for debugging and monitoring — returns price with 8 decimals
     *      Do NOT use this for protocol math — use getUsdValue() instead
     */
    function getRawPrice(address token) external view returns (int256 price) {
        if (!s_allowedCollateral[token]) {
            revert PriceOracle__TokenNotAllowed(token);
        }
        (, price, , , ) = AggregatorV3Interface(s_priceFeeds[token]).latestRoundData();
    }

    // ──────────────────────────────────────────────────────────────
    // INTERNAL FUNCTIONS
    // ──────────────────────────────────────────────────────────────

    /**
     * @dev Internal logic for registering a collateral token
     *      Called by both initialize() and addCollateral()
     * @param token     The ERC20 token address
     * @param priceFeed The Chainlink aggregator address
     */
    function _addCollateral(address token, address priceFeed) internal {
        if (token == address(0) || priceFeed == address(0)) {
            revert PriceOracle__ZeroAddress();
        }
        s_priceFeeds[token] = priceFeed;
        s_allowedCollateral[token] = true;
        emit CollateralAdded(token, priceFeed);
    }

    /**
     * @notice Required by UUPS — only the owner can authorise an upgrade
     * @dev This is the key security function in UUPS.
     *      OpenZeppelin's UUPSUpgradeable calls _authorizeUpgrade() before
     *      executing any upgrade. By restricting it to onlyOwner, only the
     *      protocol admin (or multisig in production) can upgrade the contract.
     *
     *      If this function had no access control, ANYONE could upgrade the
     *      implementation to a malicious contract — that is a critical vulnerability.
     *      The `onlyOwner` modifier is what makes UUPS safe.
     *
     * @param newImplementation The address of the new implementation contract
     *                          (we don't use it here, but the signature is required)
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
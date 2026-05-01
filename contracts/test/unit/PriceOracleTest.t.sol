// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracle} from "../../src/libraries/PriceOracle.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";
import {LendingConstants} from "../../src/libraries/LendingConstants.sol";

/**
 * @title PriceOracleTest
 * @notice Tests every function and edge case in PriceOracle.sol
 *
 * @dev TESTING UPGRADEABLE CONTRACTS:
 *      We cannot just deploy PriceOracle directly and call initialize().
 *      In production it sits behind a proxy, and we must replicate that here.
 *
 *      Deployment pattern for UUPS:
 *      1. Deploy the implementation contract (PriceOracle)
 *      2. Deploy ERC1967Proxy pointing at the implementation
 *      3. Encode the initialize() call as the proxy constructor data
 *      4. All subsequent calls go through the proxy — same as production
 *
 *      This way our tests use the EXACT same setup as the real deployment.
 */
contract PriceOracleTest is Test {
    // ──────────────────────────────────────────────────────────────
    // CONTRACTS
    // ──────────────────────────────────────────────────────────────

    // We interact with PriceOracle through the proxy address
    // Cast the proxy address to PriceOracle type for clean function calls
    PriceOracle oracle;

    MockWETH weth;
    MockWBTC wbtc;
    MockUSDC usdc;
    MockV3Aggregator ethUsdFeed;
    MockV3Aggregator btcUsdFeed;

    // ──────────────────────────────────────────────────────────────
    // CONSTANTS
    // ──────────────────────────────────────────────────────────────

    int256 constant ETH_PRICE  = 2000e8;   // $2,000
    int256 constant BTC_PRICE  = 60_000e8; // $60,000

    address ADMIN = makeAddr("admin");
    address USER  = makeAddr("user");

    // ──────────────────────────────────────────────────────────────
    // SETUP
    // ──────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy mock tokens
        weth = new MockWETH();
        wbtc = new MockWBTC();
        usdc = new MockUSDC();

        // Deploy mock Chainlink feeds
        ethUsdFeed = new MockV3Aggregator(8, ETH_PRICE);
        btcUsdFeed = new MockV3Aggregator(8, BTC_PRICE);

        // ── Deploy PriceOracle behind a UUPS proxy ─────────────────
        // Step 1: Deploy the bare implementation (no state yet)
        PriceOracle implementation = new PriceOracle();

        // Step 2: Encode the initialize() call we want the proxy to execute
        address[] memory tokens    = new address[](2);
        address[] memory feeds     = new address[](2);
        tokens[0] = address(weth);  feeds[0] = address(ethUsdFeed);
        tokens[1] = address(wbtc);  feeds[1] = address(btcUsdFeed);

        bytes memory initData = abi.encodeWithSelector(
            PriceOracle.initialize.selector,
            tokens,
            feeds,
            ADMIN
        );

        // Step 3: Deploy the proxy — it calls initialize() in its constructor
        // ERC1967Proxy is OpenZeppelin's standard UUPS-compatible proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Step 4: Cast proxy address to PriceOracle type for clean calls
        // Every call to `oracle` actually goes through the proxy → implementation
        oracle = PriceOracle(address(proxy));
    }

    // ──────────────────────────────────────────────────────────────
    // INITIALISATION TESTS
    // ──────────────────────────────────────────────────────────────

    function test_Initialize_SetsOwnerCorrectly() public view {
        // ADMIN passed to initialize() should be the owner
        assertEq(oracle.owner(), ADMIN);
    }

    function test_Initialize_RegistersWETHFeed() public view {
        // WETH price feed should be registered after initialisation
        assertEq(oracle.getPriceFeed(address(weth)), address(ethUsdFeed));
    }

    function test_Initialize_RegistersWBTCFeed() public view {
        assertEq(oracle.getPriceFeed(address(wbtc)), address(btcUsdFeed));
    }

    function test_Initialize_AllowsWETHAsCollateral() public view {
        assertTrue(oracle.isAllowedCollateral(address(weth)));
    }

    function test_Initialize_AllowsWBTCAsCollateral() public view {
        assertTrue(oracle.isAllowedCollateral(address(wbtc)));
    }

    function test_Initialize_DoesNotAllowUnregisteredToken() public view {
        // USDC was not registered in setUp — should not be allowed
        assertFalse(oracle.isAllowedCollateral(address(usdc)));
    }

    // ──────────────────────────────────────────────────────────────
    // USD VALUE CALCULATION TESTS
    // ──────────────────────────────────────────────────────────────

    /**
     * @dev WETH decimal example:
     *      1 WETH = 1e18 units, price = $2000
     *      expected = 2000e18 (USD value in 18-decimal precision)
     */
    function test_GetUsdValue_1WETH_At2000() public view {
        uint256 amount = 1e18; // 1 WETH
        uint256 usdValue = oracle.getUsdValue(address(weth), amount);

        // $2000 expressed in 18-decimal precision
        uint256 expected = 2000e18;
        assertEq(usdValue, expected);
        console2.log("1 WETH USD value:", usdValue / 1e18, "USD");
    }

    /**
     * @dev WBTC decimal example:
     *      1 WBTC = 1e8 units (8 decimals), price = $60,000
     *      expected = 60000e18
     */
    function test_GetUsdValue_1WBTC_At60000() public view {
        uint256 amount = 1e8; // 1 WBTC
        uint256 usdValue = oracle.getUsdValue(address(wbtc), amount);

        uint256 expected = 60_000e18;
        assertEq(usdValue, expected);
        console2.log("1 WBTC USD value:", usdValue / 1e18, "USD");
    }

    function test_GetUsdValue_HalfWETH() public view {
        uint256 amount = 0.5e18; // 0.5 WETH
        uint256 usdValue = oracle.getUsdValue(address(weth), amount);

        // 0.5 ETH × $2000 = $1000
        uint256 expected = 1000e18;
        assertEq(usdValue, expected);
    }

    function test_GetUsdValue_ZeroAmount() public view {
        // Zero amount should return zero value — no revert
        uint256 usdValue = oracle.getUsdValue(address(weth), 0);
        assertEq(usdValue, 0);
    }

    function test_GetUsdValue_UpdatedPrice() public {
        // Price drops from $2000 to $1000 — value should halve
        ethUsdFeed.updateAnswer(1000e8);

        uint256 amount = 1e18; // 1 WETH
        uint256 usdValue = oracle.getUsdValue(address(weth), amount);

        uint256 expected = 1000e18; // $1000
        assertEq(usdValue, expected);
    }

    // ──────────────────────────────────────────────────────────────
    // SECURITY / ERROR TESTS
    // ──────────────────────────────────────────────────────────────

    function test_Revert_UnallowedToken() public {
        // Trying to get price of an unregistered token should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracle.PriceOracle__TokenNotAllowed.selector,
                address(usdc)
            )
        );
        oracle.getUsdValue(address(usdc), 1000e6);
    }

    function test_Revert_StalePrice() public {
        // Simulate time passing beyond FEED_TIMEOUT (1 hour = 3600 seconds)
        // vm.warp moves block.timestamp forward in tests
        vm.warp(block.timestamp + LendingConstants.FEED_TIMEOUT + 1);

        // The price feed was NOT updated — so it is now stale
        // getUsdValue should detect this and revert
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracle.PriceOracle__StalePrice.selector,
                address(weth),
                block.timestamp - LendingConstants.FEED_TIMEOUT - 1
            )
        );
        oracle.getUsdValue(address(weth), 1e18);
    }

    function test_NoRevert_PriceUpdatedBeforeTimeout() public {
        // Move forward 30 minutes (within the 1-hour timeout)
        vm.warp(block.timestamp + 1800);

        // Update the price within the timeout window
        ethUsdFeed.updateAnswer(1900e8);

        // Should NOT revert — price was updated recently
        uint256 usdValue = oracle.getUsdValue(address(weth), 1e18);
        assertEq(usdValue, 1900e18);
    }

    function test_Revert_NegativePrice() public {
        // Chainlink returning a negative price is an edge case (e.g. crude oil 2020)
        // Our oracle must reject it to prevent the protocol from using garbage data
        ethUsdFeed.updateAnswer(-1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracle.PriceOracle__InvalidPrice.selector,
                int256(-1)
            )
        );
        oracle.getUsdValue(address(weth), 1e18);
    }

    function test_Revert_ZeroPrice() public {
        // A price of zero means the feed is broken — reject it
        ethUsdFeed.updateAnswer(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracle.PriceOracle__InvalidPrice.selector,
                int256(0)
            )
        );
        oracle.getUsdValue(address(weth), 1e18);
    }

    // ──────────────────────────────────────────────────────────────
    // ACCESS CONTROL TESTS
    // ──────────────────────────────────────────────────────────────

    function test_AddCollateral_OnlyOwner() public {
        // Non-owner trying to add a collateral token should revert
        vm.prank(USER); // Next call comes from USER, not ADMIN
        vm.expectRevert();
        oracle.addCollateral(address(usdc), address(ethUsdFeed));
    }

    function test_AddCollateral_OwnerCanAdd() public {
        // ADMIN can add USDC as a collateral token
        vm.prank(ADMIN);
        oracle.addCollateral(address(usdc), address(ethUsdFeed));

        assertTrue(oracle.isAllowedCollateral(address(usdc)));
        assertEq(oracle.getPriceFeed(address(usdc)), address(ethUsdFeed));
    }

    function test_AddCollateral_EmitsEvent() public {
        // Check that CollateralAdded event fires with correct args
        vm.expectEmit(true, true, false, false);
        emit PriceOracle.CollateralAdded(address(usdc), address(ethUsdFeed));

        vm.prank(ADMIN);
        oracle.addCollateral(address(usdc), address(ethUsdFeed));
    }

    function test_AddCollateral_RevertZeroTokenAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(PriceOracle.PriceOracle__ZeroAddress.selector);
        oracle.addCollateral(address(0), address(ethUsdFeed));
    }

    function test_AddCollateral_RevertZeroFeedAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(PriceOracle.PriceOracle__ZeroAddress.selector);
        oracle.addCollateral(address(usdc), address(0));
    }

    // ──────────────────────────────────────────────────────────────
    // FUZZ TESTS
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: for any valid amount, USD value must be proportional to price
     * @dev Foundry generates 1000 random `amount` values and runs this test each time
     *      This catches edge cases around very large or very small numbers
     *      that you would never think to test manually.
     *
     *      We bound amount to prevent overflow in the test assertion math
     */
    function testFuzz_GetUsdValue_ProportionalToAmount(uint256 amount) public view {
        // Bound amount to a realistic range: 0 to 1 million WETH
        amount = bound(amount, 0, 1_000_000e18);

        uint256 usdValue = oracle.getUsdValue(address(weth), amount);

        // USD value should equal: amount × price / 1e18
        // price18 = 2000e8 * 1e10 = 2000e18
        // usdValue = (2000e18 * amount) / 1e18 = 2000 * amount / 1e18 * 1e18
        uint256 expected = (uint256(ETH_PRICE) * LendingConstants.ADDITIONAL_FEED_PRECISION * amount) / 1e18;
        assertEq(usdValue, expected);
    }

    /**
     * @notice Fuzz test: USD value should scale linearly — double the amount, double the value
     */
    function testFuzz_GetUsdValue_LinearScaling(uint256 amount) public view {
        amount = bound(amount, 1, 500_000e18); // Keep in range to avoid overflow

        uint256 singleValue = oracle.getUsdValue(address(weth), amount);
        uint256 doubleValue = oracle.getUsdValue(address(weth), amount * 2);

        // doubleValue should be exactly 2× singleValue
        assertEq(doubleValue, singleValue * 2);
    }
}
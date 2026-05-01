// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";

/**
 * @title MocksTest
 * @notice Verifies that our mock contracts behave exactly as expected
 *         before we build anything on top of them.
 *
 * @dev Foundry testing conventions:
 *      - Test contracts inherit from Test
 *      - Every function starting with "test" is run automatically
 *      - setUp() runs before EVERY test function
 *      - console2.log() prints to terminal during tests
 *      - assertEq(a, b) fails the test if a != b
 */
contract MocksTest is Test {
    // ──────────────────────────────────────────────────────────────
    // CONTRACT INSTANCES
    // ──────────────────────────────────────────────────────────────

    MockUSDC usdc;
    MockWETH weth;
    MockWBTC wbtc;
    MockV3Aggregator ethUsdFeed;
    MockV3Aggregator btcUsdFeed;

    // ──────────────────────────────────────────────────────────────
    // TEST CONSTANTS
    // ──────────────────────────────────────────────────────────────

    // Starting prices — realistic 2025 values
    int256 constant ETH_USD_PRICE = 2000e8;  // $2,000.00000000
    int256 constant BTC_USD_PRICE = 60000e8; // $60,000.00000000

    // A fake user address — Foundry's makeAddr creates a deterministic address
    address USER = makeAddr("user");

    // ──────────────────────────────────────────────────────────────
    // SETUP — runs before every test
    // ──────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy all mock contracts
        // "this" contract (MocksTest) is the owner — it can call mint()
        usdc = new MockUSDC();
        weth = new MockWETH();
        wbtc = new MockWBTC();

        // Deploy price feeds with 8 decimals and starting prices
        ethUsdFeed = new MockV3Aggregator(8, ETH_USD_PRICE);
        btcUsdFeed = new MockV3Aggregator(8, BTC_USD_PRICE);
    }

    // ──────────────────────────────────────────────────────────────
    // TOKEN TESTS
    // ──────────────────────────────────────────────────────────────

    function test_USDC_HasCorrect6Decimals() public view {
        // Real USDC has 6 decimals — our mock must match
        assertEq(usdc.decimals(), 6);
        console2.log("USDC decimals:", usdc.decimals());
    }

    function test_WBTC_HasCorrect8Decimals() public view {
        // Real WBTC has 8 decimals (matching Bitcoin satoshis)
        assertEq(wbtc.decimals(), 8);
        console2.log("WBTC decimals:", wbtc.decimals());
    }

    function test_WETH_HasCorrect18Decimals() public view {
        // WETH mirrors native ETH — 18 decimals (wei)
        assertEq(weth.decimals(), 18);
        console2.log("WETH decimals:", weth.decimals());
    }

    function test_CanMintUSDCToUser() public {
        // Mint 1000 USDC (1000 * 1e6 because USDC has 6 decimals)
        uint256 amount = 1000e6;
        usdc.mint(USER, amount);

        assertEq(usdc.balanceOf(USER), amount);
        console2.log("User USDC balance:", usdc.balanceOf(USER));
    }

    function test_CanMintWETHToUser() public {
        // Mint 5 WETH (5 * 1e18 because WETH has 18 decimals)
        uint256 amount = 5e18;
        weth.mint(USER, amount);

        assertEq(weth.balanceOf(USER), amount);
    }

    function test_CanMintWBTCToUser() public {
        // Mint 1 WBTC (1 * 1e8 because WBTC has 8 decimals)
        uint256 amount = 1e8;
        wbtc.mint(USER, amount);

        assertEq(wbtc.balanceOf(USER), amount);
    }

    function test_NonOwnerCannotMintUSDC() public {
        // USER is not the owner — minting should revert
        // vm.prank makes the NEXT call come from USER instead of this test contract
        vm.prank(USER);
        vm.expectRevert(); // We expect ANY revert here
        usdc.mint(USER, 1000e6);
    }

    // ──────────────────────────────────────────────────────────────
    // PRICE FEED TESTS
    // ──────────────────────────────────────────────────────────────

    function test_EthFeed_ReturnsCorrectInitialPrice() public view {
        // latestRoundData() returns 5 values — we only care about answer (index 1)
        (, int256 price,,,) = ethUsdFeed.latestRoundData();
        assertEq(price, ETH_USD_PRICE);
        console2.log("ETH/USD price:", uint256(price));
        // Expected output: 200000000000 (2000 * 1e8)
    }

    function test_EthFeed_HasCorrect8Decimals() public view {
        assertEq(ethUsdFeed.getDecimals(), 8);
    }

    function test_CanUpdateEthPrice() public {
        // Simulate ETH crashing to $500
        int256 newPrice = 500e8;
        ethUsdFeed.updateAnswer(newPrice);

        (, int256 price,,,) = ethUsdFeed.latestRoundData();
        assertEq(price, newPrice);
        console2.log("ETH crashed to:", uint256(price) / 1e8, "USD");
    }

    function test_FeedUpdatesRoundId() public {
        // Each price update should increment the round ID
        (uint80 roundIdBefore,,,,) = ethUsdFeed.latestRoundData();

        ethUsdFeed.updateAnswer(1500e8); // Update price

        (uint80 roundIdAfter,,,,) = ethUsdFeed.latestRoundData();
        assertEq(roundIdAfter, roundIdBefore + 1);
    }

    function test_FeedUpdatesTimestamp() public {
        // After an update, updatedAt should equal block.timestamp
        ethUsdFeed.updateAnswer(1800e8);

        (,,,uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        assertEq(updatedAt, block.timestamp);
        // This is what our staleness check in PriceOracle will verify
    }
}
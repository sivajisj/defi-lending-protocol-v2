// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockWBTC} from "../src/mocks/MockWBTC.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

/**
 * @title HelperConfig
 * @notice Provides network-specific addresses for deployment and tests.
 *         Anvil local → deploys mocks automatically.
 *         Sepolia     → uses real Chainlink feed addresses.
 */
contract HelperConfig is Script {
    // ─── Config struct ────────────────────────────────────────────

    struct NetworkConfig {
        address weth;
        address wbtc;
        address usdc;
        address ethUsdFeed;
        address btcUsdFeed;
        address admin;
        uint256 deployerKey;
    }

    // ─── Chain IDs ────────────────────────────────────────────────

    uint256 constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 constant ANVIL_CHAIN_ID   = 31337;

    // ─── Anvil default key ────────────────────────────────────────
    // This is the well-known Anvil account #0 private key.
    // Safe to hardcode — it is public knowledge and only holds test ETH.
    uint256 constant ANVIL_DEFAULT_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig private activeConfig;

    function getActiveConfig() external view returns (NetworkConfig memory) {
        return activeConfig;
    }

    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeConfig = _getSepoliaConfig();
        } else {
            activeConfig = _getOrCreateAnvilConfig();
        }
    }

    // ─── Sepolia — real Chainlink feeds ───────────────────────────

    function _getSepoliaConfig()
        internal
        view
        returns (NetworkConfig memory)
    {
        return NetworkConfig({
            // Real WETH on Sepolia
            weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            // Real WBTC on Sepolia (mock — no real WBTC on Sepolia)
            wbtc: 0x29f2D40B0605204364af54EC677bD022dA425d03,
            // Real USDC on Sepolia
            usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
            // Chainlink ETH/USD on Sepolia
            ethUsdFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            // Chainlink BTC/USD on Sepolia
            btcUsdFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            admin: vm.envAddress("ADMIN_ADDRESS"),
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    // ─── Anvil — deploy mocks ─────────────────────────────────────

    function _getOrCreateAnvilConfig()
        internal
        returns (NetworkConfig memory)
    {
        // If already created, return cached config
        if (activeConfig.weth != address(0)) return activeConfig;

        vm.startBroadcast(ANVIL_DEFAULT_KEY);

        MockWETH weth = new MockWETH();
        MockWBTC wbtc = new MockWBTC();
        MockUSDC usdc = new MockUSDC();

        // ETH at $2,000, BTC at $60,000 — 8 decimal Chainlink format
        MockV3Aggregator ethFeed = new MockV3Aggregator(8, 2000e8);
        MockV3Aggregator btcFeed = new MockV3Aggregator(8, 60_000e8);

        vm.stopBroadcast();

        return NetworkConfig({
            weth: address(weth),
            wbtc: address(wbtc),
            usdc: address(usdc),
            ethUsdFeed: address(ethFeed),
            btcUsdFeed: address(btcFeed),
            admin: vm.addr(ANVIL_DEFAULT_KEY),
            deployerKey: ANVIL_DEFAULT_KEY
        });
    }
}
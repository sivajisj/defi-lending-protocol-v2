// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy}     from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HelperConfig}      from "../src/HelperConfig.s.sol";
import {PriceOracle}       from "../src/libraries/PriceOracle.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {BorrowEngine}      from "../src/BorrowEngine.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {LendingPool}       from "../src/LendingPool.sol";

/**
 * @title Deploy
 * @notice Deploys the full lending protocol in the correct order.
 *
 * Deployment order matters because of dependencies:
 *   PriceOracle has no dependencies      → deploy first
 *   CollateralManager needs PriceOracle  → deploy second
 *   BorrowEngine needs CollateralManager → deploy third
 *   LiquidationEngine needs all above    → deploy fourth
 *   LendingPool needs all above          → deploy fifth
 *   Wire: set LendingPool in all contracts → last
 *
 * Run on Sepolia:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {
    // ─── 5% APR initial borrow rate ───────────────────────────────
    uint256 constant INITIAL_APR = 5e16;

    // ─── Initial USDC liquidity to seed into protocol ─────────────
    // 10,000 USDC — enough for testnet demos
    uint256 constant INITIAL_LIQUIDITY = 10_000e6;

    function run()
        external
        returns (
            LendingPool       lendingPool,
            CollateralManager collateralManager,
            BorrowEngine      borrowEngine,
            LiquidationEngine liquidationEngine,
            PriceOracle       oracle,
            HelperConfig      config
        )
    {
        // Load network config — mocks on Anvil, real addresses on Sepolia
        config = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = config.getActiveConfig();

        console2.log("=== Deploying DeFi Lending Protocol ===");
        console2.log("Network chain ID:", block.chainid);
        console2.log("Deployer:        ", cfg.admin);
        console2.log("WETH:            ", cfg.weth);
        console2.log("WBTC:            ", cfg.wbtc);
        console2.log("USDC:            ", cfg.usdc);
        console2.log("ETH/USD feed:    ", cfg.ethUsdFeed);
        console2.log("BTC/USD feed:    ", cfg.btcUsdFeed);

        vm.startBroadcast(cfg.deployerKey);

        // ── 1. PriceOracle ────────────────────────────────────────
        console2.log("\n[1/5] Deploying PriceOracle...");
        oracle = _deployPriceOracle(cfg);
        console2.log("PriceOracle proxy:", address(oracle));

        // ── 2. CollateralManager ──────────────────────────────────
        console2.log("\n[2/5] Deploying CollateralManager...");
        collateralManager = _deployCollateralManager(cfg, address(oracle));
        console2.log("CollateralManager proxy:", address(collateralManager));

        // ── 3. BorrowEngine ───────────────────────────────────────
        console2.log("\n[3/5] Deploying BorrowEngine...");
        borrowEngine = _deployBorrowEngine(
            cfg,
            address(collateralManager)
        );
        console2.log("BorrowEngine proxy:", address(borrowEngine));

        // ── 4. LiquidationEngine ──────────────────────────────────
        console2.log("\n[4/5] Deploying LiquidationEngine...");
        liquidationEngine = _deployLiquidationEngine(
            cfg,
            address(collateralManager),
            address(borrowEngine),
            address(oracle)
        );
        console2.log("LiquidationEngine proxy:", address(liquidationEngine));

        // ── 5. LendingPool ────────────────────────────────────────
        console2.log("\n[5/5] Deploying LendingPool...");
        lendingPool = _deployLendingPool(
            cfg,
            address(collateralManager),
            address(borrowEngine),
            address(liquidationEngine)
        );
        console2.log("LendingPool proxy:", address(lendingPool));

        // ── 6. Wire contracts ─────────────────────────────────────
        console2.log("\n[6/6] Wiring contracts...");
        collateralManager.setLendingPool(address(lendingPool));
        borrowEngine.setLendingPool(address(lendingPool));
        liquidationEngine.setLendingPool(address(lendingPool));
        console2.log("All contracts wired to LendingPool");

        vm.stopBroadcast();

        // ── Print final summary ───────────────────────────────────
        console2.log("\n=== Deployment Complete ===");
        console2.log("LendingPool:       ", address(lendingPool));
        console2.log("CollateralManager: ", address(collateralManager));
        console2.log("BorrowEngine:      ", address(borrowEngine));
        console2.log("LiquidationEngine: ", address(liquidationEngine));
        console2.log("PriceOracle:       ", address(oracle));
        console2.log("\nVerify on Etherscan:");
        console2.log("https://sepolia.etherscan.io/address/",
            address(lendingPool));

        return (
            lendingPool,
            collateralManager,
            borrowEngine,
            liquidationEngine,
            oracle,
            config
        );
    }

    // ─── Internal deploy helpers ──────────────────────────────────

    function _deployPriceOracle(
        HelperConfig.NetworkConfig memory cfg
    ) internal returns (PriceOracle) {
        PriceOracle impl = new PriceOracle();

        address[] memory tokens = new address[](2);
        address[] memory feeds  = new address[](2);
        tokens[0] = cfg.weth;  feeds[0] = cfg.ethUsdFeed;
        tokens[1] = cfg.wbtc;  feeds[1] = cfg.btcUsdFeed;

        bytes memory initData = abi.encodeWithSelector(
            PriceOracle.initialize.selector,
            tokens,
            feeds,
            cfg.admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return PriceOracle(address(proxy));
    }

    function _deployCollateralManager(
        HelperConfig.NetworkConfig memory cfg,
        address oracle
    ) internal returns (CollateralManager) {
        CollateralManager impl = new CollateralManager();

        bytes memory initData = abi.encodeWithSelector(
            CollateralManager.initialize.selector,
            oracle,
            cfg.admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return CollateralManager(address(proxy));
    }

    function _deployBorrowEngine(
        HelperConfig.NetworkConfig memory cfg,
        address collateralManager
    ) internal returns (BorrowEngine) {
        BorrowEngine impl = new BorrowEngine();

        bytes memory initData = abi.encodeWithSelector(
            BorrowEngine.initialize.selector,
            cfg.usdc,
            collateralManager,
            INITIAL_APR,
            cfg.admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return BorrowEngine(address(proxy));
    }

    function _deployLiquidationEngine(
        HelperConfig.NetworkConfig memory cfg,
        address collateralManager,
        address borrowEngine,
        address oracle
    ) internal returns (LiquidationEngine) {
        LiquidationEngine impl = new LiquidationEngine();

        bytes memory initData = abi.encodeWithSelector(
            LiquidationEngine.initialize.selector,
            collateralManager,
            borrowEngine,
            oracle,
            cfg.usdc,
            cfg.admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return LiquidationEngine(address(proxy));
    }

    function _deployLendingPool(
        HelperConfig.NetworkConfig memory cfg,
        address collateralManager,
        address borrowEngine,
        address liquidationEngine
    ) internal returns (LendingPool) {
        LendingPool impl = new LendingPool();

        address[] memory allowedTokens = new address[](2);
        allowedTokens[0] = cfg.weth;
        allowedTokens[1] = cfg.wbtc;

        bytes memory initData = abi.encodeWithSelector(
            LendingPool.initialize.selector,
            collateralManager,
            borrowEngine,
            liquidationEngine,
            allowedTokens,
            cfg.admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return LendingPool(address(proxy));
    }
}
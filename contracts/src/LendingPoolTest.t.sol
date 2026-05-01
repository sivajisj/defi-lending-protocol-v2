// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LendingPool}       from "../../src/LendingPool.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {BorrowEngine}      from "../../src/BorrowEngine.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {PriceOracle}       from "../../src/libraries/PriceOracle.sol";
import {MockWETH}          from "../../src/mocks/MockWETH.sol";
import {MockWBTC}          from "../../src/mocks/MockWBTC.sol";
import {MockUSDC}          from "../../src/mocks/MockUSDC.sol";
import {MockV3Aggregator}  from "../../src/mocks/MockV3Aggregator.sol";
import {LendingConstants}  from "../../src/libraries/LendingConstants.sol";

/**
 * @title LendingPoolTest
 * @notice Integration tests — full user journeys through the complete protocol.
 *         Every test deploys the full system and exercises real user flows.
 */
contract LendingPoolTest is Test {
    // ─── Contracts ────────────────────────────────────────────────

    LendingPool       lendingPool;
    CollateralManager collateralManager;
    BorrowEngine      borrowEngine;
    LiquidationEngine liquidationEngine;
    PriceOracle       oracle;

    MockWETH          weth;
    MockWBTC          wbtc;
    MockUSDC          usdc;
    MockV3Aggregator  ethFeed;
    MockV3Aggregator  btcFeed;

    // ─── Actors ───────────────────────────────────────────────────

    address ADMIN   = makeAddr("admin");
    address USER    = makeAddr("user");
    address USER2   = makeAddr("user2");
    address LIQUIDATOR = makeAddr("liquidator");

    // ─── Constants ────────────────────────────────────────────────

    int256  constant ETH_PRICE     = 2000e8;
    int256  constant BTC_PRICE     = 60_000e8;
    uint256 constant APR_5PCT      = 5e16;
    uint256 constant USDC_LIQUIDITY = 500_000e6; // $500k in protocol

    uint256 constant USER_WETH     = 10e18;      // 10 WETH = $20,000
    uint256 constant SAFE_BORROW   = 5_000e6;    // $5,000 USDC
    uint256 constant MAX_BORROW    = 13_000e6;   // near 150% limit

    // ─── Setup — deploys the full protocol ────────────────────────

    function setUp() public {
        // Tokens and feeds
        weth    = new MockWETH();
        wbtc    = new MockWBTC();
        usdc    = new MockUSDC();
        ethFeed = new MockV3Aggregator(8, ETH_PRICE);
        btcFeed = new MockV3Aggregator(8, BTC_PRICE);

        // ── 1. PriceOracle ────────────────────────────────────────
        {
            PriceOracle impl = new PriceOracle();
            address[] memory tokens = new address[](2);
            address[] memory feeds  = new address[](2);
            tokens[0] = address(weth); feeds[0] = address(ethFeed);
            tokens[1] = address(wbtc); feeds[1] = address(btcFeed);
            bytes memory init = abi.encodeWithSelector(
                PriceOracle.initialize.selector, tokens, feeds, ADMIN
            );
            oracle = PriceOracle(
                address(new ERC1967Proxy(address(impl), init))
            );
        }

        // ── 2. CollateralManager ──────────────────────────────────
        {
            CollateralManager impl = new CollateralManager();
            bytes memory init = abi.encodeWithSelector(
                CollateralManager.initialize.selector,
                address(oracle), ADMIN
            );
            collateralManager = CollateralManager(
                address(new ERC1967Proxy(address(impl), init))
            );
        }

        // ── 3. BorrowEngine ───────────────────────────────────────
        {
            BorrowEngine impl = new BorrowEngine();
            bytes memory init = abi.encodeWithSelector(
                BorrowEngine.initialize.selector,
                address(usdc),
                address(collateralManager),
                APR_5PCT,
                ADMIN
            );
            borrowEngine = BorrowEngine(
                address(new ERC1967Proxy(address(impl), init))
            );
        }

        // ── 4. LiquidationEngine ──────────────────────────────────
        {
            LiquidationEngine impl = new LiquidationEngine();
            bytes memory init = abi.encodeWithSelector(
                LiquidationEngine.initialize.selector,
                address(collateralManager),
                address(borrowEngine),
                address(oracle),
                address(usdc),
                ADMIN
            );
            liquidationEngine = LiquidationEngine(
                address(new ERC1967Proxy(address(impl), init))
            );
        }

        // ── 5. LendingPool ────────────────────────────────────────
        {
            LendingPool impl = new LendingPool();
            address[] memory allowed = new address[](2);
            allowed[0] = address(weth);
            allowed[1] = address(wbtc);
            bytes memory init = abi.encodeWithSelector(
                LendingPool.initialize.selector,
                address(collateralManager),
                address(borrowEngine),
                allowed,
                ADMIN,
                address(liquidationEngine)
            );
            lendingPool = LendingPool(
                address(new ERC1967Proxy(address(impl), init))
            );
        }

        // ── 6. Wire LendingPool into internal contracts ───────────
        // Seed USDC before pranking — MockUSDC only allows deployer (this contract) to mint
        usdc.mint(ADMIN, USDC_LIQUIDITY);

        vm.startPrank(ADMIN);
        collateralManager.setLendingPool(address(lendingPool));
        borrowEngine.setLendingPool(address(lendingPool));
        liquidationEngine.setLendingPool(address(lendingPool));

        usdc.approve(address(borrowEngine), USDC_LIQUIDITY);
        borrowEngine.depositLiquidity(USDC_LIQUIDITY);
        vm.stopPrank();

        // ── 6. Fund USER ──────────────────────────────────────────
        weth.mint(USER, USER_WETH);
        vm.prank(USER);
        // User approves CollateralManager (not LendingPool) for token pull
        weth.approve(address(collateralManager), type(uint256).max);
    }

    // ─── Full journey tests ───────────────────────────────────────

    /**
     * @notice Complete happy path:
     *         deposit → borrow → repay → withdraw
     */
    function test_FullJourney_DepositBorrowRepayWithdraw() public {
        // 1. Deposit 10 WETH
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        (uint256 colUsd,,, ) = lendingPool.getUserPosition(USER);
        assertEq(colUsd, 20_000e18); // $20,000
       console2.log("Step 1 - collateral:", colUsd / 1e18, "USD");

        // 2. Borrow $5,000 USDC
        vm.prank(USER);
        lendingPool.borrowUSDC(SAFE_BORROW);

        assertEq(usdc.balanceOf(USER), SAFE_BORROW);
        (, uint256 debt, uint256 hf,) = lendingPool.getUserPosition(USER);
        assertGt(hf, LendingConstants.MIN_HEALTH_FACTOR);
        console2.log("Step 2 - debt:", debt / 1e6, "USDC  hf:", hf);

        // 3. Repay full debt
        // Mint extra USDC to cover any interest accrued
        usdc.mint(USER, 100e6);
        vm.startPrank(USER);
        usdc.approve(address(borrowEngine), type(uint256).max);
        lendingPool.repayUSDC(SAFE_BORROW + 100e6);
        vm.stopPrank();

        (, uint256 debtAfterRepay,,) = lendingPool.getUserPosition(USER);
        assertEq(debtAfterRepay, 0);
        console2.log("Step 3 - debt after repay:", debtAfterRepay);

        // 4. Withdraw all collateral
        vm.prank(USER);
        lendingPool.withdrawCollateral(address(weth), USER_WETH);

        assertEq(weth.balanceOf(USER), USER_WETH);
        (uint256 finalCol,,,) = lendingPool.getUserPosition(USER);
        assertEq(finalCol, 0);
        console2.log("Step 4 - collateral after withdraw:", finalCol);
    }

    // ─── Deposit tests ────────────────────────────────────────────

    function test_Deposit_UpdatesCollateralValue() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        (uint256 colUsd,,,) = lendingPool.getUserPosition(USER);
        assertEq(colUsd, 20_000e18);
    }

    function test_Deposit_Revert_TokenNotAllowed() public {
        // USDC is not whitelisted as collateral
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingPool.LendingPool__TokenNotAllowed.selector,
                address(usdc)
            )
        );
        lendingPool.depositCollateral(address(usdc), 1000e6);
    }

    function test_Deposit_Revert_ZeroAmount() public {
        vm.prank(USER);
        vm.expectRevert(LendingPool.LendingPool__ZeroAmount.selector);
        lendingPool.depositCollateral(address(weth), 0);
    }

    // ─── Withdraw tests ───────────────────────────────────────────

    function test_Withdraw_NoDebt_SucceedsAlways() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        // No debt — can withdraw freely
        vm.prank(USER);
        lendingPool.withdrawCollateral(address(weth), USER_WETH);

        assertEq(weth.balanceOf(USER), USER_WETH);
    }

    function test_Withdraw_Revert_WouldBreakHealthFactor() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        // Borrow near the limit
        vm.prank(USER);
        lendingPool.borrowUSDC(MAX_BORROW);

        // Try to withdraw all collateral — would make position undercollateralised
        vm.prank(USER);
        vm.expectRevert();
        lendingPool.withdrawCollateral(address(weth), USER_WETH);
    }

    function test_Withdraw_Partial_KeepsPositionSafe() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        vm.prank(USER);
        lendingPool.borrowUSDC(SAFE_BORROW); // $5k borrow on $20k collateral

        // Withdraw half the collateral — still overcollateralised
        vm.prank(USER);
        lendingPool.withdrawCollateral(address(weth), 5e18); // withdraw 5 WETH

        (,, uint256 hf,) = lendingPool.getUserPosition(USER);
        assertGt(hf, LendingConstants.MIN_HEALTH_FACTOR);
        console2.log("Health factor after partial withdraw:", hf);
    }

    // ─── Borrow tests ─────────────────────────────────────────────

    function test_Borrow_UserReceivesUSDC() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        vm.prank(USER);
        lendingPool.borrowUSDC(SAFE_BORROW);

        assertEq(usdc.balanceOf(USER), SAFE_BORROW);
    }

    function test_Borrow_Revert_NoCollateral() public {
        // USER2 has no collateral — cannot borrow
        vm.prank(USER2);
        vm.expectRevert();
        lendingPool.borrowUSDC(SAFE_BORROW);
    }

    function test_Borrow_Revert_ExceedsCollateralRatio() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        // $20,000 collateral → max borrow ~$13,333 at 150% ratio
        // $15,000 exceeds this — should revert
        vm.prank(USER);
        vm.expectRevert();
        lendingPool.borrowUSDC(15_000e6);
    }

    // ─── Price crash + liquidation eligibility ────────────────────

    function test_PriceCrash_MakesPositionLiquidatable() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        vm.prank(USER);
        lendingPool.borrowUSDC(MAX_BORROW);

        (,,, bool liqBefore) = lendingPool.getUserPosition(USER);
        assertFalse(liqBefore); // safe before crash

        // ETH drops 70%
        ethFeed.updateAnswer(600e8);

        (,,, bool liqAfter) = lendingPool.getUserPosition(USER);
        assertTrue(liqAfter); // liquidatable after crash
        console2.log("Position is liquidatable after crash:", liqAfter);
    }

    function test_PriceCrash_BlocksWithdrawal() public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        vm.prank(USER);
        lendingPool.borrowUSDC(MAX_BORROW);

        ethFeed.updateAnswer(600e8); // crash

        // Cannot withdraw — health factor already broken
        vm.prank(USER);
        vm.expectRevert();
        lendingPool.withdrawCollateral(address(weth), 1e18);
    }

    // ─── getUserPosition ──────────────────────────────────────────

    function test_GetUserPosition_ReturnsZerosForNewUser() public view {
        (uint256 col, uint256 debt, uint256 hf, bool liq) =
            lendingPool.getUserPosition(USER2);

        assertEq(col, 0);
        assertEq(debt, 0);
        assertEq(hf, type(uint256).max); // infinite — no debt
        assertFalse(liq);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────

    function testFuzz_Deposit_ValueAlwaysCorrect(uint256 wethAmount) public {
        // Any WETH deposit should result in correct USD valuation
        wethAmount = bound(wethAmount, 1e15, USER_WETH); // 0.001 to 10 WETH

        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), wethAmount);

        (uint256 colUsd,,,) = lendingPool.getUserPosition(USER);

        // colUsd = wethAmount × $2000
        uint256 expected = (wethAmount * 2000e18) / 1e18;
        assertEq(colUsd, expected);
    }

    function testFuzz_SafeBorrow_HealthFactorAlwaysAboveOne(
        uint256 borrowAmt
    ) public {
        vm.prank(USER);
        lendingPool.depositCollateral(address(weth), USER_WETH);

        // Max safe borrow with $20k collateral at 150% ratio ≈ $13,333
        borrowAmt = bound(borrowAmt, 1e6, 13_000e6);

        vm.prank(USER);
        lendingPool.borrowUSDC(borrowAmt);

        (,, uint256 hf,) = lendingPool.getUserPosition(USER);
        assertGe(hf, LendingConstants.MIN_HEALTH_FACTOR);
    }
}
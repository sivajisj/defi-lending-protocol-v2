// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LendingPool}         from "../../src/LendingPool.sol";
import {LiquidationEngine}   from "../../src/LiquidationEngine.sol";
import {CollateralManager}   from "../../src/CollateralManager.sol";
import {BorrowEngine}        from "../../src/BorrowEngine.sol";
import {PriceOracle}         from "../../src/libraries/PriceOracle.sol";
import {MockWETH}            from "../../src/mocks/MockWETH.sol";
import {MockUSDC}            from "../../src/mocks/MockUSDC.sol";
import {MockV3Aggregator}    from "../../src/mocks/MockV3Aggregator.sol";
import {LendingConstants}    from "../../src/libraries/LendingConstants.sol";

contract LiquidationEngineTest is Test {
    // ─── Contracts ────────────────────────────────────────────────

    LendingPool       lendingPool;
    LiquidationEngine liquidationEngine;
    CollateralManager collateralManager;
    BorrowEngine      borrowEngine;
    PriceOracle       oracle;

    MockWETH         weth;
    MockUSDC         usdc;
    MockV3Aggregator ethFeed;

    // ─── Actors ───────────────────────────────────────────────────

    address ADMIN      = makeAddr("admin");
    address BORROWER   = makeAddr("borrower");
    address LIQUIDATOR = makeAddr("liquidator");

    // ─── Constants ────────────────────────────────────────────────

    int256  constant ETH_PRICE      = 2000e8;
    uint256 constant APR_5PCT       = 5e16;
    uint256 constant USDC_LIQUIDITY = 500_000e6;

    uint256 constant BORROWER_WETH  = 10e18;     // 10 WETH = $20,000
    uint256 constant BORROW_AMOUNT  = 13_000e6;  // $13,000 — near limit
    uint256 constant REPAY_AMOUNT   = 6_500e6;   // $6,500 — half the debt

    // ─── Setup ────────────────────────────────────────────────────

    function setUp() public {
        weth    = new MockWETH();
        usdc    = new MockUSDC();
        ethFeed = new MockV3Aggregator(8, ETH_PRICE);

        // PriceOracle
        {
            PriceOracle impl = new PriceOracle();
            address[] memory tokens = new address[](1);
            address[] memory feeds  = new address[](1);
            tokens[0] = address(weth); feeds[0] = address(ethFeed);
            oracle = PriceOracle(address(new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    PriceOracle.initialize.selector,
                    tokens, feeds, ADMIN
                )
            )));
        }

        // CollateralManager
        {
            CollateralManager impl = new CollateralManager();
            collateralManager = CollateralManager(address(new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    CollateralManager.initialize.selector,
                    address(oracle), ADMIN
                )
            )));
        }

        // BorrowEngine
        {
            BorrowEngine impl = new BorrowEngine();
            borrowEngine = BorrowEngine(address(new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    BorrowEngine.initialize.selector,
                    address(usdc),
                    address(collateralManager),
                    APR_5PCT, ADMIN
                )
            )));
        }

        // LiquidationEngine
        {
            LiquidationEngine impl = new LiquidationEngine();
            liquidationEngine = LiquidationEngine(address(new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    LiquidationEngine.initialize.selector,
                    address(collateralManager),
                    address(borrowEngine),
                    address(oracle),
                    address(usdc),
                    ADMIN
                )
            )));
        }

        // LendingPool
        {
            LendingPool impl = new LendingPool();
            address[] memory allowed = new address[](1);
            allowed[0] = address(weth);
            lendingPool = LendingPool(address(new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    LendingPool.initialize.selector,
                    address(collateralManager),
                    address(borrowEngine),
                    allowed,
                    ADMIN,
                    address(liquidationEngine)
                )
            )));
        }

        // Seed USDC before pranking — MockUSDC only allows deployer (this contract) to mint
        usdc.mint(ADMIN, USDC_LIQUIDITY);

        // Wire everything
        vm.startPrank(ADMIN);
        collateralManager.setLendingPool(address(lendingPool));
        borrowEngine.setLendingPool(address(lendingPool));
        liquidationEngine.setLendingPool(address(lendingPool));

        usdc.approve(address(borrowEngine), USDC_LIQUIDITY);
        borrowEngine.depositLiquidity(USDC_LIQUIDITY);
        vm.stopPrank();

        // Fund and set up BORROWER
        weth.mint(BORROWER, BORROWER_WETH);
        vm.prank(BORROWER);
        weth.approve(address(collateralManager), type(uint256).max);

        // BORROWER deposits collateral and borrows near limit
        vm.prank(BORROWER);
        lendingPool.depositCollateral(address(weth), BORROWER_WETH);
        vm.prank(BORROWER);
        lendingPool.borrowUSDC(BORROW_AMOUNT);

        // Crash ETH price to make position liquidatable
        // $20,000 collateral × 80% = $16,000 adjusted
        // Debt = $13,000 → health factor = 16000/13000 = 1.23 (still safe)
        // Crash to $900: $9,000 × 80% = $7,200 → hf = 7200/13000 = 0.55 (liquidatable)
        ethFeed.updateAnswer(900e8);

        // Fund LIQUIDATOR with USDC to repay debt
        usdc.mint(LIQUIDATOR, 50_000e6);
        vm.prank(LIQUIDATOR);
        usdc.approve(address(liquidationEngine), type(uint256).max);
    }

    // ─── Liquidation eligibility ──────────────────────────────────

    function test_PositionIsLiquidatableAfterCrash() public view {
        assertTrue(liquidationEngine.isLiquidatable(BORROWER));
    }

    function test_HealthFactorBelowOneAfterCrash() public view {
        uint256 hf = borrowEngine.getHealthFactor(BORROWER);
        assertLt(hf, LendingConstants.MIN_HEALTH_FACTOR);
        console2.log("Health factor after crash:", hf);
    }

    // ─── Successful liquidation ───────────────────────────────────

    function test_Liquidate_ReducesBorrowerDebt() public {
        uint256 debtBefore = borrowEngine.getUserDebt(BORROWER);

        vm.prank(LIQUIDATOR);
        lendingPool.liquidate(BORROWER, address(weth), REPAY_AMOUNT);

        uint256 debtAfter = borrowEngine.getUserDebt(BORROWER);
        assertLt(debtAfter, debtBefore);
        console2.log("Debt before:", debtBefore / 1e6, "USDC");
        console2.log("Debt after: ", debtAfter  / 1e6, "USDC");
    }

    function test_Liquidate_LiquidatorReceivesCollateral() public {
        uint256 wethBefore = weth.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        lendingPool.liquidate(BORROWER, address(weth), REPAY_AMOUNT);

        uint256 wethAfter = weth.balanceOf(LIQUIDATOR);
        assertGt(wethAfter, wethBefore);

        uint256 wethGained = wethAfter - wethBefore;
        console2.log("WETH received by liquidator:", wethGained);
    }

    function test_Liquidate_LiquidatorPaysUSDC() public {
        uint256 usdcBefore = usdc.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        lendingPool.liquidate(BORROWER, address(weth), REPAY_AMOUNT);

        uint256 usdcAfter = usdc.balanceOf(LIQUIDATOR);
        assertEq(usdcBefore - usdcAfter, REPAY_AMOUNT);
    }

    function test_Liquidate_CollateralIncludesTenPercentBonus() public {
        // Preview what the liquidator should receive
        uint256 preview = liquidationEngine.previewLiquidation(
            address(weth),
            REPAY_AMOUNT
        );

        uint256 wethBefore = weth.balanceOf(LIQUIDATOR);
        vm.prank(LIQUIDATOR);
        lendingPool.liquidate(BORROWER, address(weth), REPAY_AMOUNT);
        uint256 wethGained = weth.balanceOf(LIQUIDATOR) - wethBefore;

        // Actual seized should match preview
        assertEq(wethGained, preview);

        // Verify the 10% bonus:
        // repaid $6,500, ETH at $900
        // without bonus: 6500e6 × 1e12 × 1e18 / 900e18 = 7.222 WETH
        // with 10% bonus: 7.222 × 1.10 = 7.944 WETH
        uint256 withoutBonus = (REPAY_AMOUNT * 1e12 * 1e18) / (900e18);
        uint256 expectedBonus = withoutBonus / 10;
        assertApproxEqRel(wethGained, withoutBonus + expectedBonus, 0.001e18);

        console2.log("WETH seized:    ", wethGained);
        console2.log("Without bonus:  ", withoutBonus);
        console2.log("Expected bonus: ", expectedBonus);
    }

    function test_Liquidate_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit LiquidationEngine.Liquidated(
            LIQUIDATOR, BORROWER, REPAY_AMOUNT, address(weth), 0
        );

        vm.prank(LIQUIDATOR);
        lendingPool.liquidate(BORROWER, address(weth), REPAY_AMOUNT);
    }

    // ─── Revert cases ─────────────────────────────────────────────

    function test_Revert_LiquidateHealthyPosition() public {
        // Restore price — position becomes healthy again
        ethFeed.updateAnswer(ETH_PRICE);

        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        lendingPool.liquidate(BORROWER, address(weth), REPAY_AMOUNT);
    }

    function test_Revert_LiquidateMoreThanDebt() public {
        uint256 totalDebt = borrowEngine.getUserDebt(BORROWER);

        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        lendingPool.liquidate(BORROWER, address(weth), totalDebt + 1e6);
    }

    function test_Revert_LiquidateZeroAmount() public {
        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        lendingPool.liquidate(BORROWER, address(weth), 0);
    }

    // ─── Preview ──────────────────────────────────────────────────

    function test_Preview_ReturnsCorrectCollateral() public view {
        // Repaying $1,000 USDC with ETH at $900 and 10% bonus
        // bonusDebt = 1000 × 1.10 = 1100
        // WETH = 1100e6 × 1e12 × 1e18 / (900e18) ≈ 1.222 WETH
        uint256 preview = liquidationEngine.previewLiquidation(
            address(weth),
            1_000e6
        );
        console2.log("Preview for $1000 repay:", preview);

        // Should be approximately 1.222 WETH
        assertApproxEqRel(preview, 1.222e18, 0.01e18);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────

    function testFuzz_Liquidate_CollateralAlwaysMoreThanDebtRepaid(
        uint256 repayAmount
    ) public {
        uint256 totalDebt = borrowEngine.getUserDebt(BORROWER);
        repayAmount = bound(repayAmount, 1e6, totalDebt);

        uint256 wethBefore = weth.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        lendingPool.liquidate(BORROWER, address(weth), repayAmount);

        uint256 wethGained = weth.balanceOf(LIQUIDATOR) - wethBefore;
        uint256 collateralUsd = oracle.getUsdValue(address(weth), wethGained);
        uint256 repayUsd18 = repayAmount * 1e12;

        // previewLiquidation returns the uncapped ideal amount.
        // If wethGained < preview, the borrower's balance was the binding cap
        // (position too underwater to cover the repayment + bonus).
        // In that case the liquidator receives all remaining collateral; the
        // protocol absorbs bad debt — the bonus guarantee does not apply.
        uint256 uncappedSeize = liquidationEngine.previewLiquidation(address(weth), repayAmount);
        if (wethGained < uncappedSeize) {
            // Cap applied: borrower's collateral was exhausted
            assertEq(collateralManager.getCollateralBalance(BORROWER, address(weth)), 0);
        } else {
            // No cap: 10% bonus must hold
            assertGe(collateralUsd, repayUsd18);
        }
    }
}
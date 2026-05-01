// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BorrowEngine} from "../../src/BorrowEngine.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {PriceOracle} from "../../src/libraries/PriceOracle.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";
import {LendingConstants} from "../../src/libraries/LendingConstants.sol";

contract BorrowEngineTest is Test {
    // ─── Contracts ────────────────────────────────────────────────

    BorrowEngine borrowEngine;
    CollateralManager collateralManager;
    PriceOracle oracle;

    MockWETH weth;
    MockWBTC wbtc;
    MockUSDC usdc;
    MockV3Aggregator ethUsdFeed;
    MockV3Aggregator btcUsdFeed;

    // ─── Actors ───────────────────────────────────────────────────

    address ADMIN        = makeAddr("admin");
    address USER         = makeAddr("user");
    address LENDING_POOL = makeAddr("lendingPool");

    // ─── Constants ────────────────────────────────────────────────

    int256  constant ETH_PRICE   = 2000e8;   // $2,000
    uint256 constant APR_5PCT    = 5e16;     // 5% in 1e18 precision
    uint256 constant USDC_SEED   = 100_000e6;// liquidity seeded into protocol

    // User deposits 10 ETH ($20,000 collateral)
    // Can borrow up to 66% = $13,333 USDC at 150% collateral ratio
    uint256 constant WETH_DEPOSIT   = 10e18;
    uint256 constant SAFE_BORROW    = 5_000e6;  // $5,000 — well within limit
    uint256 constant MAX_BORROW     = 13_000e6; // $13,000 — near limit but safe
    uint256 constant UNSAFE_BORROW  = 15_000e6; // $15,000 — exceeds limit

    // ─── Setup ────────────────────────────────────────────────────

    function setUp() public {
        // Deploy tokens and feeds
        weth = new MockWETH();
        wbtc = new MockWBTC();
        usdc = new MockUSDC();
        ethUsdFeed = new MockV3Aggregator(8, ETH_PRICE);
        btcUsdFeed = new MockV3Aggregator(8, 60_000e8);

        // Deploy PriceOracle behind proxy
        {
            PriceOracle impl = new PriceOracle();
            address[] memory tokens = new address[](2);
            address[] memory feeds  = new address[](2);
            tokens[0] = address(weth); feeds[0] = address(ethUsdFeed);
            tokens[1] = address(wbtc); feeds[1] = address(btcUsdFeed);
            bytes memory init = abi.encodeWithSelector(
                PriceOracle.initialize.selector, tokens, feeds, ADMIN
            );
            oracle = PriceOracle(address(new ERC1967Proxy(address(impl), init)));
        }

        // Deploy CollateralManager behind proxy
        {
            CollateralManager impl = new CollateralManager();
            bytes memory init = abi.encodeWithSelector(
                CollateralManager.initialize.selector,
                address(oracle), ADMIN
            );
            collateralManager = CollateralManager(
                address(new ERC1967Proxy(address(impl), init))
            );
            vm.prank(ADMIN);
            collateralManager.setLendingPool(LENDING_POOL);
        }

        // Deploy BorrowEngine behind proxy
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
            vm.prank(ADMIN);
            borrowEngine.setLendingPool(LENDING_POOL);
        }

        // Seed protocol with USDC liquidity
        usdc.mint(ADMIN, USDC_SEED);
        vm.startPrank(ADMIN);
        usdc.approve(address(borrowEngine), USDC_SEED);
        borrowEngine.depositLiquidity(USDC_SEED);
        vm.stopPrank();

        // Fund USER with WETH and deposit it as collateral
        weth.mint(USER, WETH_DEPOSIT);
        vm.prank(USER);
        weth.approve(address(collateralManager), WETH_DEPOSIT);
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);
    }

    // ─── Initialisation ───────────────────────────────────────────

    function test_Initialize_BorrowIndexStartsAt1() public view {
        // Index starts at 1e18 — no interest has accrued yet
        assertEq(borrowEngine.getBorrowIndex(), LendingConstants.PRECISION);
    }

    function test_Initialize_LiquiditySeeded() public view {
        assertEq(borrowEngine.getAvailableLiquidity(), USDC_SEED);
    }

    function test_Initialize_OwnerIsAdmin() public view {
        assertEq(borrowEngine.owner(), ADMIN);
    }

    // ─── Health factor ────────────────────────────────────────────

    function test_HealthFactor_MaxForNoBorrower() public view {
        // User with collateral and no debt = infinite health factor
        uint256 hf = borrowEngine.getHealthFactor(USER);
        assertEq(hf, type(uint256).max);
    }

    function test_HealthFactor_AboveOneAfterSafeBorrow() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        uint256 hf = borrowEngine.getHealthFactor(USER);
        assertGt(hf, LendingConstants.MIN_HEALTH_FACTOR);
        console2.log("Health factor after safe borrow:", hf);
    }

    function test_HealthFactor_DropsBelowOneAfterPriceCrash() public {
        // User borrows near their limit
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, MAX_BORROW);

        // ETH crashes 70% — collateral now worth much less
        ethUsdFeed.updateAnswer(600e8); // $2000 → $600

        uint256 hf = borrowEngine.getHealthFactor(USER);
        assertLt(hf, LendingConstants.MIN_HEALTH_FACTOR);
        console2.log("Health factor after crash:", hf);
    }

    // ─── Borrow ───────────────────────────────────────────────────

    function test_Borrow_TransfersUsdcToUser() public {
        uint256 balBefore = usdc.balanceOf(USER);

        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        assertEq(usdc.balanceOf(USER), balBefore + SAFE_BORROW);
    }

    function test_Borrow_RecordsDebtCorrectly() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        assertEq(borrowEngine.getUserDebt(USER), SAFE_BORROW);
    }

    function test_Borrow_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BorrowEngine.Borrowed(USER, SAFE_BORROW);

        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);
    }

    function test_Borrow_Revert_UnsafeAmount() public {
        // $15,000 borrow on $20,000 collateral violates 150% ratio
        vm.prank(LENDING_POOL);
        vm.expectRevert();
        borrowEngine.borrow(USER, UNSAFE_BORROW);
    }

    function test_Borrow_Revert_ZeroAmount() public {
        vm.prank(LENDING_POOL);
        vm.expectRevert(BorrowEngine.BorrowEngine__ZeroAmount.selector);
        borrowEngine.borrow(USER, 0);
    }

    function test_Borrow_Revert_NotLendingPool() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowEngine.BorrowEngine__NotLendingPool.selector, USER
            )
        );
        borrowEngine.borrow(USER, SAFE_BORROW);
    }

    function test_Borrow_Revert_InsufficientLiquidity() public {
        vm.prank(LENDING_POOL);
        vm.expectRevert();
        // Try to borrow more than protocol has
        borrowEngine.borrow(USER, USDC_SEED + 1);
    }

    // ─── Repay ────────────────────────────────────────────────────

    function test_Repay_FullDebt_ClearsBalance() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        // USER needs USDC to repay — give them extra for interest
        usdc.mint(USER, SAFE_BORROW);
        vm.prank(USER);
        usdc.approve(address(borrowEngine), type(uint256).max);

        vm.prank(LENDING_POOL);
        borrowEngine.repay(USER, SAFE_BORROW);

        assertEq(borrowEngine.getUserDebt(USER), 0);
    }

    function test_Repay_PartialDebt_ReducesBalance() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        uint256 partialRepay = 2_000e6;
        usdc.mint(USER, partialRepay);
        vm.prank(USER);
        usdc.approve(address(borrowEngine), type(uint256).max);

        vm.prank(LENDING_POOL);
        borrowEngine.repay(USER, partialRepay);

        // Remaining debt should be close to SAFE_BORROW - partialRepay
        // (slightly more due to interest accrued during the block)
        uint256 remaining = borrowEngine.getUserDebt(USER);
        assertApproxEqAbs(remaining, SAFE_BORROW - partialRepay, 1e6);
    }

    function test_Repay_EmitsEvent() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        usdc.mint(USER, SAFE_BORROW);
        vm.prank(USER);
        usdc.approve(address(borrowEngine), type(uint256).max);

        vm.expectEmit(true, false, false, false);
        emit BorrowEngine.Repaid(USER, SAFE_BORROW, 0);

        vm.prank(LENDING_POOL);
        borrowEngine.repay(USER, SAFE_BORROW);
    }

    // ─── Interest accrual ─────────────────────────────────────────

    function test_Interest_AccruesOverTime() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        uint256 debtAtBorrow = borrowEngine.getUserDebt(USER);

        // Warp 1 year forward
        vm.warp(block.timestamp + 365 days);

        uint256 debtAfterYear = borrowEngine.getUserDebt(USER);

        // Debt should have grown — interest accrued
        assertGt(debtAfterYear, debtAtBorrow);
        console2.log("Debt at borrow:   ", debtAtBorrow / 1e6, "USDC");
        console2.log("Debt after 1 year:", debtAfterYear / 1e6, "USDC");
    }

    function test_Interest_ApproximatesApr() public {
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Trigger index update with a dummy borrow attempt that will fail
        // Instead — read debt directly (uses current index in view)
        uint256 debtAfterYear = borrowEngine.getUserDebt(USER);

        // With 5% APR, $5000 USDC → ~$5250 after 1 year
        // Allow 1% tolerance for rounding in simple interest model
        uint256 expected = SAFE_BORROW + (SAFE_BORROW * 5) / 100;
        assertApproxEqRel(debtAfterYear, expected, 0.01e18); // 1% tolerance
    }

    function test_Interest_IndexGrowsOverTime() public {
        uint256 indexBefore = borrowEngine.getBorrowIndex();

        // Borrow to trigger interest accrual
        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, SAFE_BORROW);

        vm.warp(block.timestamp + 30 days);

        // Repay to trigger index update
        usdc.mint(USER, 10e6);
        vm.prank(USER);
        usdc.approve(address(borrowEngine), type(uint256).max);
        vm.prank(LENDING_POOL);
        borrowEngine.repay(USER, 1e6); // tiny repay just to trigger accrual

        uint256 indexAfter = borrowEngine.getBorrowIndex();
        assertGt(indexAfter, indexBefore);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────

    function testFuzz_HealthFactor_SafeBorrowAlwaysAboveOne(
        uint256 borrowAmount
    ) public {
        // Any borrow that is at most 66% of collateral value should be safe
        // Collateral = $20,000, max safe borrow at 150% ratio = ~$13,333
        borrowAmount = bound(borrowAmount, 1e6, 13_000e6);

        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, borrowAmount);

        uint256 hf = borrowEngine.getHealthFactor(USER);
        assertGe(hf, LendingConstants.MIN_HEALTH_FACTOR);
    }

    function testFuzz_Debt_AlwaysGreaterAfterBorrow(uint256 amount) public {
        amount = bound(amount, 1e6, 13_000e6);

        uint256 debtBefore = borrowEngine.getUserDebt(USER);

        vm.prank(LENDING_POOL);
        borrowEngine.borrow(USER, amount);

        uint256 debtAfter = borrowEngine.getUserDebt(USER);
        assertGt(debtAfter, debtBefore);
    }
}
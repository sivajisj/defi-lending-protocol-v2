// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralManager} from "src/CollateralManager.sol";
import {PriceOracle} from "../../src/libraries/PriceOracle.sol";
import {MockWETH} from "src/mocks/MockWETH.sol";
import {MockWBTC} from "src/mocks/MockWBTC.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {MockV3Aggregator} from "src/mocks/MockV3Aggregator.sol";

/**
 * @title CollateralManagerTest
 * @notice Tests all collateral deposit, withdrawal, and valuation logic.
 *
 * @dev TESTING SETUP PATTERN:
 *      We use a fake LendingPool address (makeAddr("lendingPool")) because
 *      the real LendingPool is not built yet (Step 6).
 *      This lets us test CollateralManager in complete isolation.
 *
 *      We use vm.prank(LENDING_POOL) to simulate calls coming from LendingPool.
 *      This is exactly how Foundry is designed — prank any address, test any flow.
 */
contract CollateralManagerTest is Test {
    // ──────────────────────────────────────────────────────────────
    // CONTRACTS
    // ──────────────────────────────────────────────────────────────

    CollateralManager collateralManager;
    PriceOracle oracle;

    MockWETH weth;
    MockWBTC wbtc;
    MockUSDC usdc;
    MockV3Aggregator ethUsdFeed;
    MockV3Aggregator btcUsdFeed;

    // ──────────────────────────────────────────────────────────────
    // ACTORS
    // ──────────────────────────────────────────────────────────────

    address ADMIN        = makeAddr("admin");
    address USER         = makeAddr("user");
    address USER2        = makeAddr("user2");
    // Simulates the LendingPool — the only address allowed to call deposit/withdraw
    address LENDING_POOL = makeAddr("lendingPool");
    address ATTACKER     = makeAddr("attacker");

    // ──────────────────────────────────────────────────────────────
    // CONSTANTS
    // ──────────────────────────────────────────────────────────────

    int256 constant ETH_PRICE       = 2000e8;
    int256 constant BTC_PRICE       = 60_000e8;
    uint256 constant WETH_DEPOSIT   = 2e18;     // 2 WETH
    uint256 constant WBTC_DEPOSIT   = 1e8;      // 1 WBTC
    uint256 constant INITIAL_WETH   = 10e18;    // 10 WETH starting balance
    uint256 constant INITIAL_WBTC   = 5e8;      // 5 WBTC starting balance

    // ──────────────────────────────────────────────────────────────
    // SETUP
    // ──────────────────────────────────────────────────────────────

    function setUp() public {
        // ── Deploy mock tokens ────────────────────────────────────
        weth = new MockWETH();
        wbtc = new MockWBTC();
        usdc = new MockUSDC();

        // ── Deploy mock price feeds ───────────────────────────────
        ethUsdFeed = new MockV3Aggregator(8, ETH_PRICE);
        btcUsdFeed = new MockV3Aggregator(8, BTC_PRICE);

        // ── Deploy PriceOracle behind proxy ───────────────────────
        PriceOracle oracleImpl = new PriceOracle();
        address[] memory tokens = new address[](2);
        address[] memory feeds  = new address[](2);
        tokens[0] = address(weth); feeds[0] = address(ethUsdFeed);
        tokens[1] = address(wbtc); feeds[1] = address(btcUsdFeed);

        bytes memory oracleInit = abi.encodeWithSelector(
            PriceOracle.initialize.selector,
            tokens, feeds, ADMIN
        );
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl), oracleInit
        );
        oracle = PriceOracle(address(oracleProxy));

        // ── Deploy CollateralManager (no proxy needed yet for testing) ─
        // We deploy it directly in tests to keep things simple
        // In production (Step 10) we deploy it behind a proxy too
        CollateralManager cmImpl = new CollateralManager();
        bytes memory cmInit = abi.encodeWithSelector(
            CollateralManager.initialize.selector,
            address(oracle),
            ADMIN
        );
        ERC1967Proxy cmProxy = new ERC1967Proxy(address(cmImpl), cmInit);
        collateralManager = CollateralManager(address(cmProxy));

        // ── Wire LendingPool address ──────────────────────────────
        vm.prank(ADMIN);
        collateralManager.setLendingPool(LENDING_POOL);

        // ── Fund USER with tokens ─────────────────────────────────
        weth.mint(USER, INITIAL_WETH);
        wbtc.mint(USER, INITIAL_WBTC);

        // ── USER approves CollateralManager to spend their tokens ──
        // In production the user calls approve() before depositing
        vm.startPrank(USER);
        weth.approve(address(collateralManager), type(uint256).max);
        wbtc.approve(address(collateralManager), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    // INITIALISATION TESTS
    // ──────────────────────────────────────────────────────────────

    function test_Initialize_SetsOracleCorrectly() public view {
        assertEq(collateralManager.getOracle(), address(oracle));
    }

    function test_Initialize_SetsLendingPoolCorrectly() public view {
        assertEq(collateralManager.getLendingPool(), LENDING_POOL);
    }

    function test_Initialize_OwnerIsAdmin() public view {
        assertEq(collateralManager.owner(), ADMIN);
    }

    function test_SetLendingPool_CannotSetTwice() public {
        // Once LendingPool is set, it cannot be changed
        vm.prank(ADMIN);
        vm.expectRevert(
            CollateralManager.CollateralManager__LendingPoolAlreadySet.selector
        );
        collateralManager.setLendingPool(address(1));
    }

    // ──────────────────────────────────────────────────────────────
    // DEPOSIT TESTS
    // ──────────────────────────────────────────────────────────────

    function test_Deposit_RecordsBalanceCorrectly() public {
        // Simulate LendingPool calling depositCollateral on behalf of USER
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        assertEq(
            collateralManager.getCollateralBalance(USER, address(weth)),
            WETH_DEPOSIT
        );
    }

    function test_Deposit_TransfersTokensToContract() public {
        uint256 balanceBefore = weth.balanceOf(address(collateralManager));

        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        uint256 balanceAfter = weth.balanceOf(address(collateralManager));
        assertEq(balanceAfter - balanceBefore, WETH_DEPOSIT);
    }

    function test_Deposit_DecreasesUserBalance() public {
        uint256 userBalanceBefore = weth.balanceOf(USER);

        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        assertEq(weth.balanceOf(USER), userBalanceBefore - WETH_DEPOSIT);
    }

    function test_Deposit_TracksTokenInUserList() public {
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        address[] memory userTokens = collateralManager.getUserCollateralTokens(USER);
        assertEq(userTokens.length, 1);
        assertEq(userTokens[0], address(weth));
    }

    function test_Deposit_DoesNotDuplicateTokenInList() public {
        // Depositing the same token twice should only add it to the list once
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 1e18);
        collateralManager.depositCollateral(USER, address(weth), 1e18);
        vm.stopPrank();

        address[] memory userTokens = collateralManager.getUserCollateralTokens(USER);
        assertEq(userTokens.length, 1); // Still 1, not 2
    }

    function test_Deposit_TracksMultipleTokens() public {
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);
        collateralManager.depositCollateral(USER, address(wbtc), WBTC_DEPOSIT);
        vm.stopPrank();

        address[] memory userTokens = collateralManager.getUserCollateralTokens(USER);
        assertEq(userTokens.length, 2);
    }

    function test_Deposit_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit CollateralManager.CollateralDeposited(USER, address(weth), WETH_DEPOSIT);

        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);
    }

    function test_Deposit_AccumulatesMultipleDeposits() public {
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 1e18);
        collateralManager.depositCollateral(USER, address(weth), 2e18);
        collateralManager.depositCollateral(USER, address(weth), 3e18);
        vm.stopPrank();

        // 1 + 2 + 3 = 6 WETH total
        assertEq(
            collateralManager.getCollateralBalance(USER, address(weth)),
            6e18
        );
    }

    // ──────────────────────────────────────────────────────────────
    // WITHDRAWAL TESTS
    // ──────────────────────────────────────────────────────────────

    function test_Withdraw_FullAmount() public {
        // Deposit first, then withdraw everything
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);
        collateralManager.withdrawCollateral(USER, address(weth), WETH_DEPOSIT);
        vm.stopPrank();

        assertEq(
            collateralManager.getCollateralBalance(USER, address(weth)),
            0
        );
    }

    function test_Withdraw_PartialAmount() public {
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);
        collateralManager.withdrawCollateral(USER, address(weth), 1e18); // Withdraw half
        vm.stopPrank();

        assertEq(
            collateralManager.getCollateralBalance(USER, address(weth)),
            1e18 // Half remains
        );
    }

    function test_Withdraw_ReturnsTokensToUser() public {
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        uint256 userBalanceBefore = weth.balanceOf(USER);

        vm.prank(LENDING_POOL);
        collateralManager.withdrawCollateral(USER, address(weth), WETH_DEPOSIT);

        assertEq(weth.balanceOf(USER), userBalanceBefore + WETH_DEPOSIT);
    }

    function test_Withdraw_EmitsEvent() public {
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        vm.expectEmit(true, true, false, true);
        emit CollateralManager.CollateralWithdrawn(USER, address(weth), WETH_DEPOSIT);

        vm.prank(LENDING_POOL);
        collateralManager.withdrawCollateral(USER, address(weth), WETH_DEPOSIT);
    }

    // ──────────────────────────────────────────────────────────────
    // USD VALUE TESTS
    // ──────────────────────────────────────────────────────────────

    function test_CollateralValue_SingleToken() public {
        // Deposit 2 WETH at $2000 each = $4000
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 2e18);

        uint256 valueUsd = collateralManager.getCollateralValueUsd(USER);
        assertEq(valueUsd, 4000e18); // $4,000 in 18-decimal precision
        console2.log("Collateral USD value:", valueUsd / 1e18, "USD");
    }

    function test_CollateralValue_MultipleTokens() public {
        // Deposit 2 WETH ($4000) + 1 WBTC ($60,000) = $64,000
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 2e18);
        collateralManager.depositCollateral(USER, address(wbtc), 1e8);
        vm.stopPrank();

        uint256 valueUsd = collateralManager.getCollateralValueUsd(USER);
        uint256 expected = 4000e18 + 60_000e18;
        assertEq(valueUsd, expected);
        console2.log("Total collateral value:", valueUsd / 1e18, "USD");
    }

    function test_CollateralValue_ZeroForNewUser() public view {
        // A user with no deposits should have zero collateral value
        uint256 valueUsd = collateralManager.getCollateralValueUsd(USER2);
        assertEq(valueUsd, 0);
    }

    function test_CollateralValue_UpdatesAfterPriceChange() public {
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 1e18);

        // Price was $2000 → value was $2000
        uint256 valueBefore = collateralManager.getCollateralValueUsd(USER);
        assertEq(valueBefore, 2000e18);

        // ETH crashes to $1000 → value should be $1000
        ethUsdFeed.updateAnswer(1000e8);

        uint256 valueAfter = collateralManager.getCollateralValueUsd(USER);
        assertEq(valueAfter, 1000e18);
        console2.log("Value after crash:", valueAfter / 1e18, "USD");
    }

    function test_CollateralValue_UpdatesAfterWithdrawal() public {
        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 2e18);
        // Value = $4000

        collateralManager.withdrawCollateral(USER, address(weth), 1e18);
        // Value should now be $2000
        vm.stopPrank();

        uint256 valueUsd = collateralManager.getCollateralValueUsd(USER);
        assertEq(valueUsd, 2000e18);
    }

    // ──────────────────────────────────────────────────────────────
    // ACCESS CONTROL TESTS — security critical
    // ──────────────────────────────────────────────────────────────

    function test_Revert_AttackerCannotDeposit() public {
        // An attacker cannot call depositCollateral directly
        // They must go through LendingPool
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.CollateralManager__NotLendingPool.selector,
                ATTACKER
            )
        );
        collateralManager.depositCollateral(USER, address(weth), 1e18);
    }

    function test_Revert_AttackerCannotWithdraw() public {
        // Deposit legitimately through LENDING_POOL
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), WETH_DEPOSIT);

        // Attacker tries to withdraw USER's funds directly — must fail
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.CollateralManager__NotLendingPool.selector,
                ATTACKER
            )
        );
        collateralManager.withdrawCollateral(USER, address(weth), WETH_DEPOSIT);
    }

    function test_Revert_DepositZeroAmount() public {
        vm.prank(LENDING_POOL);
        vm.expectRevert(CollateralManager.CollateralManager__ZeroAmount.selector);
        collateralManager.depositCollateral(USER, address(weth), 0);
    }

    function test_Revert_WithdrawMoreThanDeposited() public {
        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), 1e18);

        vm.prank(LENDING_POOL);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.CollateralManager__InsufficientCollateral.selector,
                USER,
                address(weth),
                2e18, // requested
                1e18  // available
            )
        );
        collateralManager.withdrawCollateral(USER, address(weth), 2e18);
    }

    function test_Revert_WithdrawZeroAmount() public {
        vm.prank(LENDING_POOL);
        vm.expectRevert(CollateralManager.CollateralManager__ZeroAmount.selector);
        collateralManager.withdrawCollateral(USER, address(weth), 0);
    }

    // ──────────────────────────────────────────────────────────────
    // FUZZ TESTS
    // ──────────────────────────────────────────────────────────────

    function testFuzz_Deposit_BalanceAlwaysCorrect(uint256 amount) public {
        // For any valid deposit amount, balance should equal exactly what was deposited
        amount = bound(amount, 1, INITIAL_WETH);

        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), amount);

        assertEq(
            collateralManager.getCollateralBalance(USER, address(weth)),
            amount
        );
    }

    function testFuzz_WithdrawAfterDeposit_BalanceIsZero(uint256 amount) public {
        // Depositing then withdrawing the same amount should always leave zero balance
        amount = bound(amount, 1, INITIAL_WETH);

        vm.startPrank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), amount);
        collateralManager.withdrawCollateral(USER, address(weth), amount);
        vm.stopPrank();

        assertEq(
            collateralManager.getCollateralBalance(USER, address(weth)),
            0
        );
    }

    function testFuzz_UsdValue_ProportionalToDeposit(uint256 amount) public {
        // USD value should always equal: deposit amount × price
        amount = bound(amount, 1, 1_000e18);

        // Mint exactly the fuzzed amount so USER always has enough balance
        weth.mint(USER, amount);

        vm.prank(LENDING_POOL);
        collateralManager.depositCollateral(USER, address(weth), amount);

        uint256 usdValue = collateralManager.getCollateralValueUsd(USER);

        // ETH at $2000 → value = amount * 2000e18 / 1e18
        uint256 expected = (amount * 2000e18) / 1e18;
        assertEq(usdValue, expected);
    }
}
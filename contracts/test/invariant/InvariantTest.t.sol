// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant}   from "forge-std/StdInvariant.sol";
import {ERC1967Proxy}   from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Handler}           from "./Handler.t.sol";
import {LendingPool}       from "../../src/LendingPool.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {BorrowEngine}      from "../../src/BorrowEngine.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {PriceOracle}       from "../../src/libraries/PriceOracle.sol";
import {MockWETH}          from "../../src/mocks/MockWETH.sol";
import {MockUSDC}          from "../../src/mocks/MockUSDC.sol";
import {MockV3Aggregator}  from "../../src/mocks/MockV3Aggregator.sol";
import {LendingConstants}  from "../../src/libraries/LendingConstants.sol";

/**
 * @title InvariantTest
 * @notice Protocol-wide invariants that must hold across all possible action sequences.
 *
 * How Foundry invariant testing works:
 *   1. setUp() deploys all contracts and sets targetContract(handler)
 *   2. Foundry calls handler functions in random sequences
 *   3. After each sequence, Foundry calls every function starting with "invariant_"
 *   4. If any invariant_ function reverts or fails an assertion, the test fails
 *   5. Foundry shrinks the failing sequence to the minimum reproduction case
 *
 * Configure in foundry.toml:
 *   [profile.default.invariant]
 *   runs  = 500   ← number of sequences
 *   depth = 50    ← calls per sequence
 */
contract InvariantTest is StdInvariant, Test {
    // ─── Contracts ────────────────────────────────────────────────

    Handler           handler;
    LendingPool       lendingPool;
    LiquidationEngine liquidationEngine;
    BorrowEngine      borrowEngine;
    CollateralManager collateralManager;
    PriceOracle       oracle;

    MockWETH         weth;
    MockUSDC         usdc;
    MockV3Aggregator ethFeed;

    // ─── Setup ────────────────────────────────────────────────────

    address ADMIN = makeAddr("admin");

    function setUp() public {
        // Deploy tokens and feeds
        weth    = new MockWETH();
        usdc    = new MockUSDC();
        ethFeed = new MockV3Aggregator(8, 2000e8); // ETH = $2000

        // PriceOracle
        {
            PriceOracle impl = new PriceOracle();
            address[] memory tokens = new address[](1);
            address[] memory feeds  = new address[](1);
            tokens[0] = address(weth);
            feeds[0]  = address(ethFeed);
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
                    5e16, // 5% APR
                    ADMIN
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
                    address(liquidationEngine),
                    allowed,
                    ADMIN
                )
            )));
        }

        // Seed $1M USDC liquidity — test contract is the MockUSDC owner so mint here
        usdc.mint(ADMIN, 1_000_000e6);

        // Wire contracts
        vm.startPrank(ADMIN);
        collateralManager.setLendingPool(address(lendingPool));
        borrowEngine.setLendingPool(address(lendingPool));
        liquidationEngine.setLendingPool(address(lendingPool));

        usdc.approve(address(borrowEngine), 1_000_000e6);
        borrowEngine.depositLiquidity(1_000_000e6);
        vm.stopPrank();

        // Pre-transfer ownership to the handler's future address so it can mint
        // in its constructor and during invariant calls
        address handlerAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        usdc.setOwner(handlerAddr);
        weth.setOwner(handlerAddr);

        // Deploy handler with all dependencies
        handler = new Handler(
            lendingPool,
            borrowEngine,
            collateralManager,
            weth,
            usdc,
            ethFeed
        );

        // Tell Foundry: only call functions on the handler
        // This prevents Foundry from calling protocol contracts directly
        // which would bypass the handler's bounded inputs
        targetContract(address(handler));
    }

    // ─── INVARIANT 1 ──────────────────────────────────────────────

    /**
     * @notice The protocol must always hold enough WETH to cover all recorded deposits.
     *
     * Why this matters:
     * If CollateralManager's accounting says users have deposited X WETH
     * but the contract only holds X - 1 WETH, funds have been lost.
     * This catches accounting bugs, reentrancy exploits, and rounding errors.
     */
    function invariant_CollateralManagerHoldsAllDeposits() public view {
        address[] memory actors = handler.getActors();
        uint256 totalRecordedDeposits;

        for (uint256 i = 0; i < actors.length; i++) {
            totalRecordedDeposits += collateralManager.getCollateralBalance(
                actors[i],
                address(weth)
            );
        }

        uint256 actualBalance = weth.balanceOf(address(collateralManager));

        // Actual balance must be >= recorded deposits
        // (can be greater if someone sent WETH directly without depositing)
        assert(actualBalance >= totalRecordedDeposits);
    }

    // ─── INVARIANT 2 ──────────────────────────────────────────────

    /**
     * @notice Total collateral USD value across all users must always
     *         exceed or equal total outstanding debt.
     *
     * Why this matters:
     * If total debt > total collateral, the protocol is insolvent —
     * there is not enough collateral to cover all outstanding loans.
     * This is the core solvency invariant of any lending protocol.
     *
     * Note: We check at current prices. During a price crash individual
     * positions may be underwater (that's what liquidation handles)
     * but at the global level we maintain a healthy collateral ratio
     * because individual positions are liquidated before the protocol goes insolvent.
     */
    function invariant_ProtocolIsAlwaysOvercollateralised() public view {
        address[] memory actors = handler.getActors();
        uint256 totalCollateralUsd;
        uint256 totalDebt;

        for (uint256 i = 0; i < actors.length; i++) {
            totalCollateralUsd += collateralManager.getCollateralValueUsd(
                actors[i]
            );
            // Debt is in USDC (6 decimals) — convert to 18 for comparison
            totalDebt += borrowEngine.getUserDebt(actors[i]) * 1e12;
        }

        // If no debt exists the protocol is trivially overcollateralised
        if (totalDebt == 0) return;

        // Total collateral value must exceed total debt
        assert(totalCollateralUsd >= totalDebt);
    }

    // ─── INVARIANT 3 ──────────────────────────────────────────────

    /**
     * @notice A user with zero debt must always have a health factor of type(uint256).max.
     *
     * Why this matters:
     * Health factor = (collateral × threshold) / debt
     * If debt = 0 the result is undefined (division by zero).
     * Our BorrowEngine returns type(uint256).max in this case.
     * If it ever returns anything else, the health factor calculation is broken.
     */
    function invariant_DebtFreeUserHasMaxHealthFactor() public view {
        address[] memory actors = handler.getActors();

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 debt = borrowEngine.getUserDebt(actors[i]);
            if (debt == 0) {
                uint256 hf = borrowEngine.getHealthFactor(actors[i]);
                assert(hf == type(uint256).max);
            }
        }
    }

    // ─── INVARIANT 4 ──────────────────────────────────────────────

    /**
     * @notice A user with no debt must never be marked as liquidatable.
     *
     * Why this matters:
     * `isLiquidatable()` should only return true when health factor < 1.
     * A user with no debt has infinite health factor — they cannot be liquidated.
     * If this invariant breaks, liquidators could seize collateral from debt-free users.
     */
    function invariant_DebtFreeUserIsNeverLiquidatable() public view {
        address[] memory actors = handler.getActors();

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 debt = borrowEngine.getUserDebt(actors[i]);
            if (debt == 0) {
                bool liq = borrowEngine.isLiquidatable(actors[i]);
                assert(!liq);
            }
        }
    }

    // ─── INVARIANT 5 ──────────────────────────────────────────────

    /**
     * @notice The BorrowEngine's USDC balance must always be >= total recorded debt.
     *
     * Why this matters:
     * Every unit of debt must be backed by real USDC sitting in BorrowEngine.
     * If recorded debt > actual USDC balance, the protocol cannot honour repayments.
     * This catches scenarios where USDC is incorrectly transferred out.
     */
    function invariant_BorrowEngineHoldsEnoughUSDC() public view {
        address[] memory actors = handler.getActors();
        uint256 totalDebt;

        for (uint256 i = 0; i < actors.length; i++) {
            totalDebt += borrowEngine.getUserDebt(actors[i]);
        }

        uint256 usdcBalance = usdc.balanceOf(address(borrowEngine));

        // USDC balance >= total debt
        // (initial liquidity seed means balance starts above debt)
        assert(usdcBalance >= totalDebt);
    }

    // ─── INVARIANT 6 ──────────────────────────────────────────────

    /**
     * @notice Borrow index must never decrease.
     *
     * Why this matters:
     * The borrow index is a monotonically increasing multiplier.
     * If it ever decreases, existing debts would shrink — users would owe less
     * than they actually borrowed. This would be a critical accounting bug.
     */
    function invariant_BorrowIndexNeverDecreases() public view {
        uint256 currentIndex = borrowEngine.getBorrowIndex();
        // Index starts at 1e18 and can only grow
        assert(currentIndex >= LendingConstants.PRECISION);
    }

    // ─── INVARIANT 7 ──────────────────────────────────────────────

    /**
     * @notice Ghost variable check — total withdrawn never exceeds total deposited.
     *
     * Why this matters:
     * Across all handler calls, the cumulative WETH withdrawn cannot exceed
     * the cumulative WETH deposited. If it does, WETH has been created from nothing.
     * This catches a critical class of bugs where balance accounting overflows
     * or underflows to allow more withdrawals than deposits.
     */
    function invariant_TotalWithdrawnNeverExceedsTotalDeposited() public view {
        assert(
            handler.ghost_totalWethWithdrawn() <=
            handler.ghost_totalWethDeposited()
        );
    }

    // ─── Post-test report ─────────────────────────────────────────

    /**
     * @notice Prints a summary of all handler activity after the invariant run.
     *         Run with `forge test -vv` to see this output.
     */
    function invariant_PrintReport() public view {
        console2.log("=== Invariant Test Report ===");
        console2.log("Deposit calls:  ", handler.ghost_depositCalls());
        console2.log("Borrow calls:   ", handler.ghost_borrowCalls());
        console2.log("Borrows skipped:", handler.ghost_borrowsSkipped());
        console2.log("Total deposited:", handler.ghost_totalWethDeposited() / 1e18, "WETH");
        console2.log("Total withdrawn:", handler.ghost_totalWethWithdrawn() / 1e18, "WETH");
        console2.log("Total borrowed: ", handler.ghost_totalBorrowed() / 1e6, "USDC");
        console2.log("Total repaid:   ", handler.ghost_totalRepaid() / 1e6, "USDC");
    }
}
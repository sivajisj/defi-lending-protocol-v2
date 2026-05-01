// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool}       from "../../src/LendingPool.sol";
import {BorrowEngine}      from "../../src/BorrowEngine.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {MockWETH}          from "../../src/mocks/MockWETH.sol";
import {MockUSDC}          from "../../src/mocks/MockUSDC.sol";
import {MockV3Aggregator}  from "../../src/mocks/MockV3Aggregator.sol";

/**
 * @title Handler
 * @notice Wraps all protocol actions for invariant testing.
 *
 * Why do we need a Handler?
 * Foundry's invariant fuzzer calls functions with completely random inputs —
 * random addresses, random amounts, random token addresses.
 * Most of those calls would revert immediately (wrong token, zero amount, etc.)
 * wasting the fuzzer's budget on useless calls.
 *
 * The Handler bounds all inputs to valid ranges and known addresses,
 * so every fuzzer call exercises real protocol logic.
 *
 * Ghost variables track cumulative state across all calls —
 * the invariant test reads these to check protocol-wide rules.
 */
contract Handler is Test {
    // ─── Protocol contracts ───────────────────────────────────────

    LendingPool       lendingPool;
    BorrowEngine      borrowEngine;
    CollateralManager collateralManager;
    MockWETH          weth;
    MockUSDC          usdc;
    MockV3Aggregator  ethFeed;

    // ─── Test actors ──────────────────────────────────────────────

    // Fixed set of users — fuzzer picks from these instead of random addresses
    address[] public actors;
    address   currentActor;

    // ─── Ghost variables ──────────────────────────────────────────
    // Track cumulative totals across all handler calls
    // The invariant contract reads these to verify protocol rules

    /// @dev Total WETH deposited across all users across all calls
    uint256 public ghost_totalWethDeposited;

    /// @dev Total WETH withdrawn across all users across all calls
    uint256 public ghost_totalWethWithdrawn;

    /// @dev Total USDC borrowed across all users across all calls
    uint256 public ghost_totalBorrowed;

    /// @dev Total USDC repaid across all users across all calls
    uint256 public ghost_totalRepaid;

    /// @dev Number of times deposit was called
    uint256 public ghost_depositCalls;

    /// @dev Number of times borrow was called
    uint256 public ghost_borrowCalls;

    /// @dev Number of times a borrow was skipped due to health factor
    uint256 public ghost_borrowsSkipped;

    // ─── Constructor ──────────────────────────────────────────────

    constructor(
        LendingPool       _lendingPool,
        BorrowEngine      _borrowEngine,
        CollateralManager _collateralManager,
        MockWETH          _weth,
        MockUSDC          _usdc,
        MockV3Aggregator  _ethFeed
    ) {
        lendingPool       = _lendingPool;
        borrowEngine      = _borrowEngine;
        collateralManager = _collateralManager;
        weth              = _weth;
        usdc              = _usdc;
        ethFeed           = _ethFeed;

        // Create 5 fixed actors — fuzzer picks from these
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));
        actors.push(makeAddr("dave"));
        actors.push(makeAddr("eve"));

        // Give each actor WETH and USDC
        for (uint256 i = 0; i < actors.length; i++) {
            weth.mint(actors[i], 1000e18);
            usdc.mint(actors[i], 1_000_000e6);

            // Pre-approve so actors don't need to approve during tests
            vm.startPrank(actors[i]);
            weth.approve(address(collateralManager), type(uint256).max);
            usdc.approve(address(borrowEngine), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ─── Action: deposit collateral ───────────────────────────────

    /**
     * @notice Deposits a bounded amount of WETH as collateral.
     * @param actorSeed  Used to pick which actor performs the action
     * @param amount     Raw amount — bounded to valid range inside
     */
    function depositCollateral(
        uint256 actorSeed,
        uint256 amount
    ) public {
        // Pick a real actor from our list
        currentActor = actors[actorSeed % actors.length];

        // Bound amount: 0.001 WETH to 100 WETH
        amount = bound(amount, 0.001e18, 100e18);

        // Ensure actor has enough — mint more if needed
        if (weth.balanceOf(currentActor) < amount) {
            weth.mint(currentActor, amount);
        }

        vm.prank(currentActor);
        lendingPool.depositCollateral(address(weth), amount);

        // Update ghost variables
        ghost_totalWethDeposited += amount;
        ghost_depositCalls++;
    }

    // ─── Action: withdraw collateral ──────────────────────────────

    /**
     * @notice Withdraws a bounded amount of WETH if the actor has any.
     *         Skips if withdrawal would break health factor.
     */
    function withdrawCollateral(
        uint256 actorSeed,
        uint256 amount
    ) public {
        currentActor = actors[actorSeed % actors.length];

        uint256 balance = collateralManager.getCollateralBalance(
            currentActor,
            address(weth)
        );

        // Nothing to withdraw — skip
        if (balance == 0) return;

        // Bound to what they actually have
        amount = bound(amount, 1, balance);

        // Try withdrawal — skip if it would break health factor
        vm.prank(currentActor);
        try lendingPool.withdrawCollateral(address(weth), amount) {
            ghost_totalWethWithdrawn += amount;
        } catch {
            // Health factor check failed — position has debt, skip gracefully
        }
    }

    // ─── Action: borrow USDC ──────────────────────────────────────

    /**
     * @notice Borrows a bounded USDC amount if the actor has collateral.
     *         Skips if borrow would violate the collateral ratio.
     */
    function borrowUsdc(
        uint256 actorSeed,
        uint256 amount
    ) public {
        currentActor = actors[actorSeed % actors.length];

        // Bound: $1 to $10,000 USDC
        amount = bound(amount, 1e6, 10_000e6);

        uint256 collateralUsd = collateralManager.getCollateralValueUsd(
            currentActor
        );

        // No collateral — cannot borrow
        if (collateralUsd == 0) return;

        // Try borrow — skip if health factor check fails
        vm.prank(currentActor);
        try lendingPool.borrowUSDC(amount) {
            ghost_totalBorrowed += amount;
            ghost_borrowCalls++;
        } catch {
            // Not enough collateral for this borrow amount — skip
            ghost_borrowsSkipped++;
        }
    }

    // ─── Action: repay USDC ───────────────────────────────────────

    /**
     * @notice Repays a bounded USDC amount for actors that have debt.
     */
    function repayUsdc(
        uint256 actorSeed,
        uint256 amount
    ) public {
        currentActor = actors[actorSeed % actors.length];

        uint256 debt = borrowEngine.getUserDebt(currentActor);

        // No debt — nothing to repay
        if (debt == 0) return;

        // Bound repayment to actual debt
        amount = bound(amount, 1e6, debt);

        // Ensure actor has enough USDC
        if (usdc.balanceOf(currentActor) < amount) {
            usdc.mint(currentActor, amount);
        }

        vm.prank(currentActor);
        lendingPool.repayUSDC(amount);

        ghost_totalRepaid += amount;
    }

    // ─── Action: warp time ────────────────────────────────────────

    /**
     * @notice Moves time forward to accrue interest.
     *         Bounded to 0-180 days per call.
     */
    function warpTime(uint256 seconds_) public {
        seconds_ = bound(seconds_, 0, 180 days);
        vm.warp(block.timestamp + seconds_);
        // Simulate oracle keepers — keep the feed timestamp current so
        // PriceOracle's FEED_TIMEOUT staleness check never trips during invariant runs
        ethFeed.updateAnswer(ethFeed.latestAnswer());
    }

    // ─── Helper: get all actors ───────────────────────────────────

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}
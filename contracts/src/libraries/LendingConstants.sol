// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LendingConstants
 * @notice Central location for every magic number in the protocol.
 *
 * @dev Why a library instead of putting constants inside each contract?
 *
 *      Imagine you need to change LIQUIDATION_THRESHOLD from 80% to 85%.
 *      If that number is copy-pasted across 6 contracts, you must update
 *      all 6 and hope you didn't miss one. One library = one change = done.
 *
 *      These are "pure" constants — no state, no deployment, no gas cost.
 *      The compiler inlines them directly into the bytecode that uses them.
 *
 * ─────────────────────────────────────────────────────────────────
 * PROTOCOL PARAMETERS EXPLAINED
 * ─────────────────────────────────────────────────────────────────
 *
 *  COLLATERAL_RATIO = 150%
 *      Users must deposit $150 of collateral to borrow $100.
 *      This 50% cushion protects the protocol from sudden price drops.
 *      Aave uses 80-85% LTV (Loan-To-Value) — we use 66% LTV (1/1.5)
 *      for simplicity and safety in this learning protocol.
 *
 *  LIQUIDATION_THRESHOLD = 80%
 *      If collateral value drops so that the loan is worth more than
 *      80% of collateral, the position becomes liquidatable.
 *      Example: deposit $150 ETH, borrow $100 USDC.
 *      If ETH drops to $125: loan ($100) / collateral ($125) = 80% → liquidatable.
 *
 *  LIQUIDATION_BONUS = 10%
 *      Liquidators get a 10% discount on collateral they seize.
 *      This incentivises third parties to liquidate risky positions quickly.
 *      Without this bonus, nobody would bother liquidating (costs gas, no reward).
 *
 *  MIN_HEALTH_FACTOR = 1e18
 *      Health factor is: (collateralValueUSD * LIQUIDATION_THRESHOLD) / totalDebtUSD
 *      If health factor >= 1.0 (1e18) → position is safe
 *      If health factor <  1.0 (1e18) → position can be liquidated
 *      We use 1e18 to represent 1.0 in 18-decimal fixed-point arithmetic.
 *
 *  PRECISION = 1e18
 *      All internal math uses 18 decimals regardless of token decimals.
 *      This is the "normalisation" that makes mixed-decimal math safe.
 *      Chainlink prices (8 decimals) are scaled up to 1e18 in PriceOracle.
 *
 *  FEED_TIMEOUT = 3600 seconds (1 hour)
 *      If Chainlink has not updated a price in over 1 hour, we reject it.
 *      This protects against a scenario where Chainlink nodes go offline
 *      and your protocol keeps operating on a 6-hour-old price during a crash.
 *      Different protocols use different timeouts — ETH/USD is usually 3600s,
 *      some exotic feeds may need 86400s (24 hours).
 *
 *  ADDITIONAL_FEED_PRECISION = 1e10
 *      Chainlink USD feeds return 8 decimal prices.
 *      Our math uses 18 decimals throughout.
 *      To convert: multiply Chainlink price by 1e10 → now it has 18 decimals.
 *      Example: ETH = $2000 → Chainlink returns 2000e8
 *               2000e8 * 1e10 = 2000e18 ✓
 */
library LendingConstants {
    // ── Precision ────────────────────────────────────────────────
    uint256 public constant PRECISION = 1e18;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;

    // ── Collateral & borrowing parameters ────────────────────────
    // 150% expressed as a ratio: collateral must be 150% of borrow value
    uint256 public constant COLLATERAL_RATIO = 150;
    // Denominator for the ratio above: 150/100 = 1.5x overcollateralised
    uint256 public constant COLLATERAL_RATIO_DENOMINATOR = 100;

    // ── Liquidation parameters ────────────────────────────────────
    // Position can be liquidated when debt exceeds 80% of collateral value
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    // Denominator for threshold: 80/100 = 80%
    uint256 public constant LIQUIDATION_THRESHOLD_DENOMINATOR = 100;
    // Liquidator receives 10% bonus on seized collateral
    uint256 public constant LIQUIDATION_BONUS = 10;
    // Denominator for bonus: 10/100 = 10%
    uint256 public constant LIQUIDATION_BONUS_DENOMINATOR = 100;

    // ── Health factor ─────────────────────────────────────────────
    // 1.0 in 18-decimal fixed-point — positions below this are liquidatable
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    // ── Oracle ────────────────────────────────────────────────────
    // Reject any Chainlink price not updated within this many seconds
    uint256 public constant FEED_TIMEOUT = 3600;
}
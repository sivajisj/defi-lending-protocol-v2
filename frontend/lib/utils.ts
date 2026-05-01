import { formatUnits, parseUnits } from "viem"

/**
 * Formats a raw uint256 from the contract into a human-readable string.
 *
 * @param value     Raw value from contract (BigInt)
 * @param decimals  Token decimals (18 for WETH, 6 for USDC)
 * @param dp        Decimal places to show in the UI
 */
export function formatAmount(
  value: bigint,
  decimals: number = 18,
  dp: number = 4
): string {
  return Number(formatUnits(value, decimals)).toFixed(dp)
}

/**
 * Parses a human-readable string into raw contract units.
 *
 * @param value     User input string e.g. "1.5"
 * @param decimals  Token decimals
 */
export function parseAmount(value: string, decimals: number = 18): bigint {
  try {
    return parseUnits(value, decimals)
  } catch {
    return 0n
  }
}

/**
 * Formats USD value from 18-decimal precision to readable string.
 * Protocol returns collateral USD values as 1e18 precision.
 * e.g. 2000e18 → "$2,000.00"
 */
export function formatUsd(value: bigint): string {
  const num = Number(formatUnits(value, 18))
  return new Intl.NumberFormat("en-US", {
    style:                 "currency",
    currency:              "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(num)
}

/**
 * Formats health factor from 1e18 precision to readable number.
 * 1e18 = 1.00 (minimum safe)
 * type(uint256).max = ∞ (no debt)
 */
export function formatHealthFactor(hf: bigint): string {
  // type(uint256).max means no debt — show infinity symbol
  if (hf === BigInt("115792089237316195423570985008687907853269984665640564039457584007913129639935")) {
    return "∞"
  }
  const num = Number(formatUnits(hf, 18))
  return num.toFixed(2)
}

/**
 * Returns the health factor status for colour coding in the UI.
 * green  = safe     (hf >= 1.5)
 * yellow = warning  (1.0 <= hf < 1.5)
 * red    = danger   (hf < 1.0)
 */
export function getHealthFactorStatus(
  hf: bigint
): "safe" | "warning" | "danger" | "none" {
  if (hf === BigInt("115792089237316195423570985008687907853269984665640564039457584007913129639935")) {
    return "none"
  }
  const num = Number(formatUnits(hf, 18))
  if (num >= 1.5) return "safe"
  if (num >= 1.0) return "warning"
  return "danger"
}

/**
 * Shortens an Ethereum address for display.
 * 0x1234...5678
 */
export function shortenAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}
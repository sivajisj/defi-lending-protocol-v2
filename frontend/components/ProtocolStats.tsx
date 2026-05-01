"use client"

import { useReadContract } from "wagmi"
import { ADDRESSES }       from "@/lib/addresses"
import { BORROW_ENGINE_ABI } from "@/lib/abis"
import { formatUnits }     from "viem"

export function ProtocolStats() {
  const { data: liquidity } = useReadContract({
    address:      ADDRESSES.borrowEngine as `0x${string}`,
    abi:          BORROW_ENGINE_ABI,
    functionName: "getAvailableLiquidity",
    query:        { refetchInterval: 15_000 },
  })

  const { data: borrowRate } = useReadContract({
    address:      ADDRESSES.borrowEngine as `0x${string}`,
    abi:          BORROW_ENGINE_ABI,
    functionName: "getBorrowRate",
    query:        { refetchInterval: 60_000 },
  })

  const stats = [
    {
      label: "Available Liquidity",
      value: liquidity
        ? `$${Number(formatUnits(liquidity as bigint, 6)).toFixed(2)}`
        : "...",
      color: "#4ade80",
    },
    {
      label: "Borrow APR",
      value: borrowRate
        ? `${(Number(formatUnits(borrowRate as bigint, 18)) * 100).toFixed(2)}%`
        : "5.00%",
      color: "#c084fc",
    },
    {
      label: "Collateral Ratio",
      value: "150%",
      color: "#60a5fa",
    },
    {
      label: "Liquidation Bonus",
      value: "10%",
      color: "#fb923c",
    },
    {
      label: "Network",
      value: "Sepolia",
      color: "#34d399",
    },
  ]

  return (
    <div style={{
      marginTop: 32,
      padding: "20px 24px",
      background: "#13131f",
      border: "1px solid #1f1f2e",
      borderRadius: 16,
      display: "flex",
      justifyContent: "space-between",
      alignItems: "center",
      flexWrap: "wrap",
      gap: 16,
    }}>
      {stats.map(s => (
        <div key={s.label} style={{ textAlign: "center" }}>
          <div style={{
            color: s.color, fontSize: 18,
            fontWeight: 700, fontFamily: "monospace"
          }}>
            {s.value}
          </div>
          <div style={{ color: "#6b7280", fontSize: 11, marginTop: 3 }}>
            {s.label}
          </div>
        </div>
      ))}

      {/* Etherscan link */}
      <a
        href={`https://sepolia.etherscan.io/address/${ADDRESSES.lendingPool}`}
        target="_blank"
        rel="noopener noreferrer"
        style={{
          display: "flex", alignItems: "center", gap: 6,
          color: "#6366f1", fontSize: 13, textDecoration: "none",
          background: "rgba(99,102,241,0.1)",
          border: "1px solid rgba(99,102,241,0.2)",
          borderRadius: 8, padding: "6px 12px",
        }}
      >
        View on Etherscan →
      </a>
    </div>
  )
}
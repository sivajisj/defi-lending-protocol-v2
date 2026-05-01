"use client"

import { useAccount }  from "wagmi"
import { usePosition } from "@/hooks/usePosition"
import { formatUsd, formatHealthFactor, getHealthFactorStatus } from "@/lib/utils"
import { formatUnits } from "viem"

function Stat({
  label, value, sub, accent
}: {
  label: string
  value: string
  sub?: string
  accent?: string
}) {
  return (
    <div style={{
      background: "#13131f",
      border: "1px solid #1f1f2e",
      borderRadius: 14,
      padding: "20px 22px"
    }}>
      <div style={{ color: "#6b7280", fontSize: 12, marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.06em" }}>
        {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 700, color: accent ?? "#ffffff", fontFamily: "monospace" }}>
        {value}
      </div>
      {sub && (
        <div style={{ color: "#4b5563", fontSize: 12, marginTop: 4 }}>
          {sub}
        </div>
      )}
    </div>
  )
}

export function PositionPanel() {
  const { isConnected } = useAccount()
  const { collateralUsd, debtUsd, healthFactor, liquidatable, isLoading } = usePosition()

  if (!isConnected) {
    return (
      <div style={{
        background: "#13131f",
        border: "1px solid #1f1f2e",
        borderRadius: 16,
        padding: "32px 24px",
        textAlign: "center"
      }}>
        <div style={{ fontSize: 40, marginBottom: 12 }}>🔗</div>
        <div style={{ color: "#9ca3af", fontSize: 15 }}>
          Connect your wallet to view your position
        </div>
      </div>
    )
  }

  if (isLoading) {
    return (
      <div style={{
        background: "#13131f", border: "1px solid #1f1f2e",
        borderRadius: 16, padding: 24
      }}>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 16 }}>
          {[...Array(4)].map((_, i) => (
            <div key={i} style={{
              height: 88, borderRadius: 14,
              background: "linear-gradient(90deg, #1f1f2e 25%, #2a2a3e 50%, #1f1f2e 75%)",
              backgroundSize: "200% 100%",
              animation: "shimmer 1.5s infinite"
            }} />
          ))}
        </div>
      </div>
    )
  }

  const hfStatus = getHealthFactorStatus(healthFactor)
  const hfColor = {
    safe:    "#4ade80",
    warning: "#facc15",
    danger:  "#f87171",
    none:    "#6b7280",
  }[hfStatus]

  const maxBorrowUsd = collateralUsd > 0n
    ? (collateralUsd * 100n / 150n) - (debtUsd * BigInt(1e12))
    : 0n

  return (
    <div>
      <div style={{
        display: "grid",
        gridTemplateColumns: "repeat(4, 1fr)",
        gap: 16, marginBottom: 16
      }}>
        <Stat
          label="Collateral Value"
          value={formatUsd(collateralUsd)}
          sub="WETH deposited"
        />
        <Stat
          label="Outstanding Debt"
          value={`$${Number(formatUnits(debtUsd, 6)).toFixed(2)}`}
          sub="USDC borrowed"
          accent="#c084fc"
        />
        <Stat
          label="Available to Borrow"
          value={maxBorrowUsd > 0n ? formatUsd(maxBorrowUsd) : "$0.00"}
          sub="at 150% ratio"
          accent="#60a5fa"
        />
        <Stat
          label="Health Factor"
          value={formatHealthFactor(healthFactor)}
          sub={hfStatus === "none" ? "no debt" : hfStatus}
          accent={hfColor}
        />
      </div>

      {liquidatable && (
        <div style={{
          background: "rgba(239,68,68,0.08)",
          border: "1px solid rgba(239,68,68,0.3)",
          borderRadius: 12, padding: "12px 16px",
          display: "flex", alignItems: "center", gap: 10
        }}>
          <span style={{ fontSize: 18 }}>⚠️</span>
          <span style={{ color: "#fca5a5", fontSize: 14, fontWeight: 500 }}>
            Your position is liquidatable. Repay debt or add collateral immediately.
          </span>
        </div>
      )}
    </div>
  )
}
"use client"

import { useState }                    from "react"
import { useAccount, useWriteContract } from "wagmi"
import { parseUnits, maxUint256 }      from "viem"
import { useTokenBalances }            from "@/hooks/useTokenBalance"
import { usePosition }                 from "@/hooks/usePosition"
import { ADDRESSES }                   from "@/lib/addresses"
import { LENDING_POOL_ABI, ERC20_ABI } from "@/lib/abis"
import { formatAmount }                from "@/lib/utils"
import { formatUnits }                 from "viem"

type Tab = "borrow" | "repay"

export function BorrowPanel() {
  const [tab, setTab]       = useState<Tab>("borrow")
  const [amount, setAmount] = useState("")
  const [step, setStep]     = useState<"idle"|"approving"|"confirming"|"done">("idle")

  const { isConnected }                                          = useAccount()
  const { usdcBalance, usdcAllowance, refetch: refetchBalances } = useTokenBalances()
  const { debtUsd, refetch: refetchPosition }                    = usePosition()
  const { writeContractAsync }                                   = useWriteContract()

  async function refetchAll() {
    await refetchBalances()
    await refetchPosition()
  }

  async function handleBorrow() {
    if (!amount) return
    try {
      setStep("confirming")
      await writeContractAsync({
        address: ADDRESSES.lendingPool as `0x${string}`,
        abi: LENDING_POOL_ABI,
        functionName: "borrowUSDC",
        args: [parseUnits(amount, 6)],
      })
      setStep("done")
      setAmount("")
      await refetchAll()
      setTimeout(() => setStep("idle"), 3000)
    } catch (err) {
      console.error(err)
      setStep("idle")
    }
  }

  async function handleRepay() {
    if (!amount) return
    const parsed = parseUnits(amount, 6)
    try {
      if (usdcAllowance < parsed) {
        setStep("approving")
        await writeContractAsync({
          address: ADDRESSES.usdc as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [ADDRESSES.borrowEngine as `0x${string}`, maxUint256],
        })
      }
      setStep("confirming")
      await writeContractAsync({
        address: ADDRESSES.lendingPool as `0x${string}`,
        abi: LENDING_POOL_ABI,
        functionName: "repayUSDC",
        args: [parsed],
      })
      setStep("done")
      setAmount("")
      await refetchAll()
      setTimeout(() => setStep("idle"), 3000)
    } catch (err) {
      console.error(err)
      setStep("idle")
    }
  }

  const needsApproval = tab === "repay" && !!amount &&
    usdcAllowance < parseUnits(amount || "0", 6)

  const btnLabel = {
    idle:       needsApproval ? "Approve & Repay" : tab === "borrow" ? "Borrow USDC" : "Repay USDC",
    approving:  "Approving...",
    confirming: "Confirming...",
    done:       "✓ Done",
  }[step]

  if (!isConnected) return (
    <div style={{
      background: "#13131f", border: "1px solid #1f1f2e",
      borderRadius: 16, padding: 24, textAlign: "center"
    }}>
      <p style={{ color: "#6b7280", fontSize: 14 }}>Connect wallet to borrow</p>
    </div>
  )

  return (
    <div style={{
      background: "#13131f",
      border: "1px solid #1f1f2e",
      borderRadius: 16,
      padding: 24,
    }}>
      {/* Header */}
      <div style={{ marginBottom: 20 }}>
        <h2 style={{ color: "#ffffff", fontSize: 18, fontWeight: 600, margin: 0 }}>
          Borrow / Repay
        </h2>
        <p style={{ color: "#6b7280", fontSize: 13, marginTop: 4 }}>
          Borrow USDC against your collateral
        </p>
      </div>

      {/* Tabs */}
      <div style={{
        display: "flex", background: "#0a0a0f",
        borderRadius: 10, padding: 4, marginBottom: 20,
        border: "1px solid #1f1f2e"
      }}>
        {(["borrow", "repay"] as Tab[]).map(t => (
          <button key={t} onClick={() => { setTab(t); setAmount("") }}
            style={{
              flex: 1, padding: "8px 0", borderRadius: 8, border: "none",
              cursor: "pointer", fontSize: 14, fontWeight: 500,
              transition: "all 0.15s",
              background: tab === t ? "#7c3aed" : "transparent",
              color: tab === t ? "#ffffff" : "#6b7280",
            }}>
            {t === "borrow" ? "Borrow" : "Repay"}
          </button>
        ))}
      </div>

      {/* Token info */}
      <div style={{
        display: "flex", justifyContent: "space-between",
        alignItems: "center", marginBottom: 10
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <div style={{
            width: 32, height: 32, borderRadius: "50%",
            background: "linear-gradient(135deg,#10b981,#059669)",
            display: "flex", alignItems: "center", justifyContent: "center",
            color: "#fff", fontWeight: 700, fontSize: 12
          }}>$</div>
          <span style={{ color: "#ffffff", fontWeight: 500 }}>USDC</span>
        </div>
        <span style={{ color: "#9ca3af", fontSize: 13, fontFamily: "monospace" }}>
          {tab === "borrow"
            ? `Debt: $${Number(formatUnits(debtUsd, 6)).toFixed(2)}`
            : `Balance: ${formatAmount(usdcBalance, 6, 2)}`}
        </span>
      </div>

      {/* Input */}
      <div style={{ position: "relative", marginBottom: 16 }}>
        <input
          type="number"
          value={amount}
          onChange={e => setAmount(e.target.value)}
          placeholder="0.00"
          style={{
            width: "100%", padding: "14px 50px 14px 16px",
            background: "#0a0a0f", border: "1px solid #2d2d3f",
            borderRadius: 10, color: "#ffffff", fontSize: 18,
            fontFamily: "monospace", outline: "none",
          }}
        />
        {tab === "repay" && (
          <button
            onClick={() => setAmount(formatAmount(usdcBalance, 6, 2))}
            style={{
              position: "absolute", right: 12, top: "50%",
              transform: "translateY(-50%)",
              background: "rgba(124,58,237,0.15)",
              border: "1px solid rgba(124,58,237,0.3)",
              borderRadius: 6, padding: "3px 8px",
              color: "#c084fc", fontSize: 11,
              cursor: "pointer", fontWeight: 600
            }}>
            MAX
          </button>
        )}
      </div>

      {/* Button */}
      <button
        onClick={tab === "borrow" ? handleBorrow : handleRepay}
        disabled={!amount || step !== "idle"}
        style={{
          width: "100%", padding: "14px 0",
          borderRadius: 12, border: "none",
          fontSize: 15, fontWeight: 600,
          cursor: step !== "idle" ? "not-allowed" : "pointer",
          background: step === "done"
            ? "#16a34a"
            : step !== "idle"
            ? "#1f1f2e"
            : "linear-gradient(135deg, #7c3aed, #6d28d9)",
          color: step !== "idle" && step !== "done" ? "#4b5563" : "#ffffff",
          transition: "all 0.2s",
        }}>
        {btnLabel}
      </button>

      {/* Protocol params */}
      <div style={{
        marginTop: 16,
        padding: "12px 14px",
        background: "rgba(124,58,237,0.05)",
        border: "1px solid rgba(124,58,237,0.15)",
        borderRadius: 10
      }}>
        <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 6 }}>
          <span style={{ color: "#6b7280", fontSize: 12 }}>Borrow APR</span>
          <span style={{ color: "#c084fc", fontSize: 12, fontFamily: "monospace" }}>5.00%</span>
        </div>
        <div style={{ display: "flex", justifyContent: "space-between" }}>
          <span style={{ color: "#6b7280", fontSize: 12 }}>Liquidation Bonus</span>
          <span style={{ color: "#c084fc", fontSize: 12, fontFamily: "monospace" }}>10%</span>
        </div>
      </div>
    </div>
  )
}
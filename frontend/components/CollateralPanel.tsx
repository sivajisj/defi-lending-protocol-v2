"use client"

import { useState }                    from "react"
import { useAccount, useWriteContract } from "wagmi"
import { parseUnits, maxUint256 }      from "viem"
import { useTokenBalances }            from "@/hooks/useTokenBalance"
import { usePosition }                 from "@/hooks/usePosition"
import { ADDRESSES }                   from "@/lib/addresses"
import { LENDING_POOL_ABI, ERC20_ABI } from "@/lib/abis"
import { formatAmount }                from "@/lib/utils"
import { Toast, useToast }             from "@/components/Toast"

type Tab = "deposit" | "withdraw"

export function CollateralPanel() {
  const [tab, setTab]       = useState<Tab>("deposit")
  const [amount, setAmount] = useState("")
  const [step, setStep]     = useState<"idle"|"approving"|"confirming"|"done">("idle")
  const { toast, showToast, hideToast } = useToast()

  const { isConnected }                                          = useAccount()
  const { wethBalance, wethAllowance, refetch: refetchBalances } = useTokenBalances()
  const { refetch: refetchPosition }                             = usePosition()
  const { writeContractAsync }                                   = useWriteContract()

  async function refetchAll() {
    await refetchBalances()
    await refetchPosition()
  }

  async function handleDeposit() {
    if (!amount) return
    const parsed = parseUnits(amount, 18)
    try {
      if (wethAllowance < parsed) {
        setStep("approving")
        showToast("Approving WETH...", "loading")
        await writeContractAsync({
          address: ADDRESSES.weth as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [ADDRESSES.collateralManager as `0x${string}`, maxUint256],
        })
      }
      setStep("confirming")
      showToast("Depositing WETH...", "loading")
      const hash = await writeContractAsync({
        address: ADDRESSES.lendingPool as `0x${string}`,
        abi: LENDING_POOL_ABI,
        functionName: "depositCollateral",
        args: [ADDRESSES.weth as `0x${string}`, parsed],
      })
      setStep("done")
      setAmount("")
      showToast("WETH deposited successfully!", "success", hash)
      await refetchAll()
      setTimeout(() => setStep("idle"), 3000)
    } catch (err: any) {
      showToast(err?.shortMessage ?? "Transaction failed", "error")
      setStep("idle")
    }
  }

  async function handleWithdraw() {
    if (!amount) return
    const parsed = parseUnits(amount, 18)
    try {
      setStep("confirming")
      showToast("Withdrawing WETH...", "loading")
      const hash = await writeContractAsync({
        address: ADDRESSES.lendingPool as `0x${string}`,
        abi: LENDING_POOL_ABI,
        functionName: "withdrawCollateral",
        args: [ADDRESSES.weth as `0x${string}`, parsed],
      })
      setStep("done")
      setAmount("")
      showToast("WETH withdrawn successfully!", "success", hash)
      await refetchAll()
      setTimeout(() => setStep("idle"), 3000)
    } catch (err: any) {
      showToast(err?.shortMessage ?? "Transaction failed", "error")
      setStep("idle")
    }
  }

  const needsApproval = tab === "deposit" && !!amount &&
    wethAllowance < parseUnits(amount || "0", 18)

  const btnLabel = {
    idle:       needsApproval ? "Approve & Deposit" : tab === "deposit" ? "Deposit WETH" : "Withdraw WETH",
    approving:  "Approving...",
    confirming: "Confirming...",
    done:       "✓ Done",
  }[step]

  if (!isConnected) return (
    <div style={{
      background: "#13131f", border: "1px solid #1f1f2e",
      borderRadius: 16, padding: 24, textAlign: "center"
    }}>
      <p style={{ color: "#6b7280", fontSize: 14 }}>Connect wallet to deposit</p>
    </div>
  )

  return (
    <>
      {toast && (
        <Toast
          message={toast.message}
          type={toast.type}
          txHash={toast.txHash}
          onClose={hideToast}
        />
      )}
      <div style={{
        background: "#13131f",
        border: "1px solid #1f1f2e",
        borderRadius: 16,
        padding: 24,
      }}>
        <div style={{ marginBottom: 20 }}>
          <h2 style={{ color: "#ffffff", fontSize: 18, fontWeight: 600, margin: 0 }}>
            Collateral
          </h2>
          <p style={{ color: "#6b7280", fontSize: 13, marginTop: 4 }}>
            Deposit WETH to unlock borrowing power
          </p>
        </div>

        <div style={{
          display: "flex", background: "#0a0a0f",
          borderRadius: 10, padding: 4, marginBottom: 20,
          border: "1px solid #1f1f2e"
        }}>
          {(["deposit", "withdraw"] as Tab[]).map(t => (
            <button key={t} onClick={() => { setTab(t); setAmount("") }}
              style={{
                flex: 1, padding: "8px 0", borderRadius: 8, border: "none",
                cursor: "pointer", fontSize: 14, fontWeight: 500,
                transition: "all 0.15s",
                background: tab === t ? "#6366f1" : "transparent",
                color: tab === t ? "#ffffff" : "#6b7280",
              }}>
              {t === "deposit" ? "Deposit" : "Withdraw"}
            </button>
          ))}
        </div>

        <div style={{
          display: "flex", justifyContent: "space-between",
          alignItems: "center", marginBottom: 10
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div style={{
              width: 32, height: 32, borderRadius: "50%",
              background: "linear-gradient(135deg,#3b82f6,#1d4ed8)",
              display: "flex", alignItems: "center", justifyContent: "center",
              color: "#fff", fontWeight: 700, fontSize: 12
            }}>W</div>
            <span style={{ color: "#ffffff", fontWeight: 500 }}>WETH</span>
          </div>
          <span style={{ color: "#9ca3af", fontSize: 13, fontFamily: "monospace" }}>
            {formatAmount(wethBalance, 18, 4)} WETH
          </span>
        </div>

        <div style={{ position: "relative", marginBottom: 16 }}>
          <input
            type="number" value={amount}
            onChange={e => setAmount(e.target.value)}
            placeholder="0.0"
            style={{
              width: "100%", padding: "14px 50px 14px 16px",
              background: "#0a0a0f", border: "1px solid #2d2d3f",
              borderRadius: 10, color: "#ffffff", fontSize: 18,
              fontFamily: "monospace", outline: "none",
            }}
          />
          <button
            onClick={() => setAmount(formatAmount(wethBalance, 18, 6))}
            style={{
              position: "absolute", right: 12, top: "50%",
              transform: "translateY(-50%)",
              background: "rgba(99,102,241,0.15)",
              border: "1px solid rgba(99,102,241,0.3)",
              borderRadius: 6, padding: "3px 8px",
              color: "#818cf8", fontSize: 11,
              cursor: "pointer", fontWeight: 600
            }}>MAX</button>
        </div>

        <button
          onClick={tab === "deposit" ? handleDeposit : handleWithdraw}
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
              : "linear-gradient(135deg, #6366f1, #8b5cf6)",
            color: step !== "idle" && step !== "done" ? "#4b5563" : "#ffffff",
            transition: "all 0.2s",
          }}>
          {btnLabel}
        </button>

        <div style={{
          marginTop: 16, padding: "12px 14px",
          background: "rgba(99,102,241,0.05)",
          border: "1px solid rgba(99,102,241,0.15)",
          borderRadius: 10
        }}>
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 6 }}>
            <span style={{ color: "#6b7280", fontSize: 12 }}>Collateral Ratio</span>
            <span style={{ color: "#a5b4fc", fontSize: 12, fontFamily: "monospace" }}>150%</span>
          </div>
          <div style={{ display: "flex", justifyContent: "space-between" }}>
            <span style={{ color: "#6b7280", fontSize: 12 }}>Liquidation Threshold</span>
            <span style={{ color: "#a5b4fc", fontSize: 12, fontFamily: "monospace" }}>80%</span>
          </div>
        </div>
      </div>
    </>
  )
}
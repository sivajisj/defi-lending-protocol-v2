"use client"

import { useEffect, useState } from "react"

type ToastType = "success" | "error" | "loading"

interface ToastProps {
  message: string
  type:    ToastType
  txHash?: string
  onClose: () => void
}

export function Toast({ message, type, txHash, onClose }: ToastProps) {
  useEffect(() => {
    if (type === "success" || type === "error") {
      const timer = setTimeout(onClose, 5000)
      return () => clearTimeout(timer)
    }
  }, [type, onClose])

  const bg        = type === "success" ? "#052e16" : type === "error" ? "#2d0a0a" : "#0f172a"
  const border    = type === "success" ? "#16a34a" : type === "error" ? "#dc2626" : "#6366f1"
  const icon      = type === "success" ? "✓"       : type === "error" ? "✗"       : "⟳"
  const iconColor = type === "success" ? "#4ade80" : type === "error" ? "#f87171" : "#818cf8"

  const etherscanUrl = txHash
    ? "https://sepolia.etherscan.io/tx/" + txHash
    : ""

  return (
    <div style={{
      position: "fixed", bottom: 24, right: 24, zIndex: 1000,
      background: bg, border: "1px solid " + border,
      borderRadius: 12, padding: "14px 18px",
      display: "flex", alignItems: "center", gap: 12,
      minWidth: 280, maxWidth: 400,
      boxShadow: "0 8px 32px rgba(0,0,0,0.4)",
    }}>
      <div style={{
        width: 28, height: 28, borderRadius: "50%",
        background: iconColor + "20",
        display: "flex", alignItems: "center", justifyContent: "center",
        color: iconColor, fontWeight: 700, fontSize: 14, flexShrink: 0,
      }}>
        {icon}
      </div>

      <div style={{ flex: 1 }}>
        <div style={{ color: "#ffffff", fontSize: 14, fontWeight: 500 }}>
          {message}
        </div>
        {txHash && (
          <a
            href={etherscanUrl}
            target="_blank"
            rel="noopener noreferrer"
            style={{
              color: "#6366f1", fontSize: 12,
              textDecoration: "none", fontFamily: "monospace",
            }}
          >
            View on Etherscan
          </a>
        )}
      </div>

      {type !== "loading" && (
        <button onClick={onClose} style={{
          background: "none", border: "none",
          color: "#4b5563", cursor: "pointer",
          fontSize: 18, lineHeight: 1, flexShrink: 0,
        }}>
          x
        </button>
      )}
    </div>
  )
}

interface ToastState {
  message: string
  type:    ToastType
  txHash?: string
}

export function useToast() {
  const [toast, setToast] = useState<ToastState | null>(null)

  function showToast(message: string, type: ToastType, txHash?: string) {
    setToast({ message, type, txHash })
  }

  function hideToast() {
    setToast(null)
  }

  return { toast, showToast, hideToast }
}


"use client"

import { ConnectButton } from "@rainbow-me/rainbowkit"

export function Navbar() {
  return (
    <nav style={{
      borderBottom: "1px solid #1f1f2e",
      background: "rgba(10,10,15,0.95)",
      backdropFilter: "blur(12px)",
      position: "sticky", top: 0, zIndex: 50
    }}>
      <div style={{
        maxWidth: 1100, margin: "0 auto",
        padding: "0 20px", height: 64,
        display: "flex", alignItems: "center", justifyContent: "space-between"
      }}>

        {/* Logo */}
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <div style={{
            width: 36, height: 36, borderRadius: 10,
            background: "linear-gradient(135deg, #6366f1, #8b5cf6)",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 16, fontWeight: 700, color: "#fff"
          }}>D</div>
          <div>
            <div style={{ fontWeight: 700, color: "#ffffff", fontSize: 16, lineHeight: 1 }}>
              DeFi Lend
            </div>
            <div style={{ color: "#6366f1", fontSize: 11, fontFamily: "monospace" }}>
              Sepolia Testnet
            </div>
          </div>
        </div>

        <ConnectButton />
      </div>
    </nav>
  )
}
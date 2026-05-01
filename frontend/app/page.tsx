import { Navbar }          from "@/components/Navbar"
import { PositionPanel }   from "@/components/PositionPanel"
import { CollateralPanel } from "@/components/CollateralPanel"
import { BorrowPanel }     from "@/components/BorrowPanel"
import { ProtocolStats } from "@/components/ProtocolStats"

export default function Home() {
  return (
    <main style={{ minHeight: "100vh", background: "#0a0a0f" }}>
      <Navbar />
      <div style={{ maxWidth: 1100, margin: "0 auto", padding: "32px 20px" }}>

        {/* Header */}
        <div style={{ marginBottom: 32 }}>
          <div style={{
            display: "inline-flex", alignItems: "center", gap: 8,
            background: "rgba(99,102,241,0.12)", border: "1px solid rgba(99,102,241,0.3)",
            borderRadius: 20, padding: "4px 12px", marginBottom: 12
          }}>
            <div style={{ width: 6, height: 6, borderRadius: "50%", background: "#4ade80" }} />
            <span style={{ color: "#a5b4fc", fontSize: 12, fontFamily: "monospace" }}>
              LIVE ON SEPOLIA
            </span>
          </div>
          <h1 style={{ fontSize: 36, fontWeight: 700, color: "#ffffff", margin: 0, lineHeight: 1.2 }}>
            DeFi Lending Protocol
          </h1>
          <p style={{ color: "#6b7280", marginTop: 6, fontSize: 15 }}>
            Deposit WETH collateral · Borrow USDC · Earn yield
          </p>
        </div>

        {/* Position */}
        <div style={{ marginBottom: 24 }}>
          <PositionPanel />
        </div>

        {/* Actions */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 20 }}>
          <CollateralPanel />
          <BorrowPanel />
        </div>

      </div>

      <div style={{ marginTop: 0 }}>
  <ProtocolStats />
</div>
    </main>
  )
}
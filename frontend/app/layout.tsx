import type { Metadata } from "next"
import { Inter }         from "next/font/google"
import { Providers }     from "./providers"
import "./globals.css"

const inter = Inter({ subsets: ["latin"] })

export const metadata: Metadata = {
  title:       "DeFi Lending Protocol",
  description: "Deposit collateral, borrow USDC, earn yield on Sepolia",
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body className={inter.className}>
        <Providers>
          {children}
        </Providers>
      </body>
    </html>
  )
}
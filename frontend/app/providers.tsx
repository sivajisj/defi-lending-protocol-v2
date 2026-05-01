"use client"

import { useState, useEffect }          from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { RainbowKitProvider }           from "@rainbow-me/rainbowkit"
import { WagmiProvider }                from "wagmi"
import { wagmiConfig }                  from "@/lib/wagmi"
import "@rainbow-me/rainbowkit/styles.css"

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 10_000 },
  },
})

export function Providers({ children }: { children: React.ReactNode }) {
  // Prevent hydration mismatch — only render Web3 providers on client
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>
          {mounted ? children : null}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
import { getDefaultConfig } from "@rainbow-me/rainbowkit"
import { sepolia } from "wagmi/chains"
import { phantomWallet, metaMaskWallet } from "@rainbow-me/rainbowkit/wallets"


/**
 * Wagmi configuration.
 * We only support Sepolia — our contracts are deployed there.
 * RainbowKit handles wallet detection and connection UI.
 */
export const wagmiConfig = getDefaultConfig({
  appName:   "DeFi Lending Protocol",
  projectId: process.env.NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID!,
  chains:    [sepolia],
  ssr:       true,
  wallets: [
    {
      groupName: "Recommended",
      wallets:   [phantomWallet, metaMaskWallet],
    },
  ],
})
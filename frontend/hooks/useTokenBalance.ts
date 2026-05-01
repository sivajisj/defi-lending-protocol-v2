"use client"

import { useAccount, useReadContracts } from "wagmi"
import { ERC20_ABI }                    from "@/lib/abis"
import { ADDRESSES }                    from "@/lib/addresses"

/**
 * Reads WETH and USDC balances for the connected wallet.
 * Also reads allowances so the UI can show if approval is needed.
 */
export function useTokenBalances() {
  const { address, isConnected } = useAccount()

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      // WETH balance
      {
        address:      ADDRESSES.weth as `0x${string}`,
        abi:          ERC20_ABI,
        functionName: "balanceOf",
        args:         [address!],
      },
      // USDC balance
      {
        address:      ADDRESSES.usdc as `0x${string}`,
        abi:          ERC20_ABI,
        functionName: "balanceOf",
        args:         [address!],
      },
      // WETH allowance for CollateralManager
      {
        address:      ADDRESSES.weth as `0x${string}`,
        abi:          ERC20_ABI,
        functionName: "allowance",
        args:         [address!, ADDRESSES.collateralManager as `0x${string}`],
      },
      // USDC allowance for BorrowEngine
      {
        address:      ADDRESSES.usdc as `0x${string}`,
        abi:          ERC20_ABI,
        functionName: "allowance",
        args:         [address!, ADDRESSES.borrowEngine as `0x${string}`],
      },
    ],
    query: {
      enabled:         isConnected && !!address,
      refetchInterval: 15_000,
    },
  })

  return {
    wethBalance:         (data?.[0]?.result as bigint) ?? 0n,
    usdcBalance:         (data?.[1]?.result as bigint) ?? 0n,
    wethAllowance:       (data?.[2]?.result as bigint) ?? 0n,
    usdcAllowance:       (data?.[3]?.result as bigint) ?? 0n,
    isLoading,
    refetch,
  }
}
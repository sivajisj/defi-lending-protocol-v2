"use client"

import { useAccount, useReadContract } from "wagmi"
import { ADDRESSES }                   from "@/lib/addresses"
import { LENDING_POOL_ABI }            from "@/lib/abis"

/**
 * Reads the user's current position from LendingPool.getUserPosition().
 * Returns collateral USD value, debt, health factor, and liquidatable flag.
 * Refreshes every 10 seconds automatically via react-query staleTime.
 */
export function usePosition() {
  const { address, isConnected } = useAccount()

  const { data, isLoading, refetch } = useReadContract({
    address:      ADDRESSES.lendingPool as `0x${string}`,
    abi:          LENDING_POOL_ABI,
    functionName: "getUserPosition",
    args:         [address!],
    query: {
      enabled:   isConnected && !!address,
      // Refetch every 15 seconds to keep position fresh
      refetchInterval: 15_000,
    },
  })

  return {
    collateralUsd: data?.[0] ?? 0n,
    debtUsd:       data?.[1] ?? 0n,
    healthFactor:  data?.[2] ?? 0n,
    liquidatable:  data?.[3] ?? false,
    isLoading,
    refetch,
  }
}
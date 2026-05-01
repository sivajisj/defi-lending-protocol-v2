/**
 * Deployed contract addresses on Sepolia.
 * These are the PROXY addresses — never change these.
 * The implementation can be upgraded, proxy address is permanent.
 */
export const ADDRESSES = {
  lendingPool:       "0xc2a7809322bdce4d50e12ba05efdc967948b4870",
  collateralManager: "0x8435576e9034bad347ea7c85da1d47db2f2f85f5",
  borrowEngine:      "0xde34ef364de76e511e83d38ad1cdeb0c4ed2f4d9",
  liquidationEngine: "0x3b1fad288e51a12ea62a841e9732ec468858ca0d",
  priceOracle:       "0x1e1abfb8152eb7509d9a5ecea2880c682443f4d6",
  weth:              "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
  wbtc:              "0x29f2D40B0605204364af54EC677bD022dA425d03",
  usdc:              "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
} as const

export const SEPOLIA_CHAIN_ID = 11155111
# DeFi Lending Protocol

A production-grade decentralised lending protocol built on Solidity with a Next.js frontend.

## Live Demo
- Contracts: https://sepolia.etherscan.io/address/0xc2a7809322bdce4d50e12ba05efdc967948b4870

## What it does
- Deposit WETH as collateral
- Borrow USDC against collateral
- Liquidate undercollateralised positions with 10% bonus
- Real Chainlink ETH/USD price feeds on Sepolia

## Stack
Solidity 0.8.24, Foundry, OpenZeppelin, Chainlink, Next.js 14, wagmi v2, RainbowKit, viem

## Deployed Contracts (Sepolia)
| Contract | Address |
|---|---|
| LendingPool | 0xc2a7809322bdce4d50e12ba05efdc967948b4870 |
| CollateralManager | 0x8435576e9034bad347ea7c85da1d47db2f2f85f5 |
| BorrowEngine | 0xde34ef364de76e511e83d38ad1cdeb0c4ed2f4d9 |
| LiquidationEngine | 0x3b1fad288e51a12ea62a841e9732ec468858ca0d |
| PriceOracle | 0x1e1abfb8152eb7509d9a5ecea2880c682443f4d6 |

## Tests
- 145+ unit and integration tests
- 8 protocol invariants proven across 25,000 fuzz sequences

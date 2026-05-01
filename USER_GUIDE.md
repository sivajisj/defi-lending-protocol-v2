# User Guide — DeFi Lending Protocol

A step-by-step guide to using the protocol on Sepolia testnet.

---

## What is this protocol?

A decentralised lending protocol where you can:

- **Deposit WETH** as collateral and earn borrowing power
- **Borrow USDC** against your collateral
- **Repay** your USDC debt at any time
- **Withdraw** your collateral when your position is healthy

All of this happens on-chain — no sign-up, no KYC, no custodian. Your funds are controlled by smart contracts, not a company.

---

## Live Contracts (Sepolia Testnet)

| Contract | Address | Etherscan |
|---|---|---|
| LendingPool | `0xc2a7809322bdce4d50e12ba05efdc967948b4870` | [View](https://sepolia.etherscan.io/address/0xc2a7809322bdce4d50e12ba05efdc967948b4870) |
| CollateralManager | `0x8435576e9034bad347ea7c85da1d47db2f2f85f5` | [View](https://sepolia.etherscan.io/address/0x8435576e9034bad347ea7c85da1d47db2f2f85f5) |
| BorrowEngine | `0xde34ef364de76e511e83d38ad1cdeb0c4ed2f4d9` | [View](https://sepolia.etherscan.io/address/0xde34ef364de76e511e83d38ad1cdeb0c4ed2f4d9) |
| LiquidationEngine | `0x3b1fad288e51a12ea62a841e9732ec468858ca0d` | [View](https://sepolia.etherscan.io/address/0x3b1fad288e51a12ea62a841e9732ec468858ca0d) |
| PriceOracle | `0x1e1abfb8152eb7509d9a5ecea2880c682443f4d6` | [View](https://sepolia.etherscan.io/address/0x1e1abfb8152eb7509d9a5ecea2880c682443f4d6) |

---

## Before You Start

You need:

1. **A wallet** — MetaMask or Phantom
2. **Sepolia ETH** for gas fees (free from a faucet)
3. **Sepolia WETH** to deposit as collateral
4. **Sepolia USDC** if you want to repay debt

This is a **testnet** — all tokens are worthless test tokens. You cannot lose real money.

---

## Step 1 — Get a Wallet

### MetaMask
1. Install from https://metamask.io
2. Create a wallet and save your seed phrase
3. Open MetaMask → Settings → Advanced → turn on **Show test networks**
4. Select **Sepolia** from the network dropdown

### Phantom
1. Install from https://phantom.app
2. Create a wallet and save your seed phrase
3. Open Phantom → Settings → Developer Settings → turn on **Testnet Mode**
4. Click the network selector → Ethereum → Sepolia

---

## Step 2 — Get Free Sepolia ETH

You need Sepolia ETH to pay for gas on every transaction.

**Option 1 — Alchemy Faucet (recommended)**
```
https://sepoliafaucet.com
```
Paste your wallet address → click Send ETH. Receive 0.5 ETH.

**Option 2 — QuickNode Faucet**
```
https://faucet.quicknode.com/ethereum/sepolia
```

**Option 3 — Chainlink Faucet**
```
https://faucets.chain.link/sepolia
```

---

## Step 3 — Get Sepolia WETH (collateral)

WETH (Wrapped ETH) is used as collateral. You wrap your Sepolia ETH into WETH.

**Using the WETH contract directly:**

Send ETH to the WETH contract address and it automatically wraps it:
```
WETH contract: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
```

In MetaMask:
1. Click **Send**
2. Paste the WETH contract address
3. Send 0.1 ETH
4. Confirm the transaction

Your wallet now shows 0.1 WETH.

**Or wrap using Uniswap:**
1. Go to https://app.uniswap.org
2. Connect your wallet
3. Select Sepolia network
4. Swap ETH → WETH

---

## Step 4 — Get Sepolia USDC (for repayment)

You only need USDC if you want to repay debt. Skip this step for now.

**Circle Faucet (official):**
```
https://faucet.circle.com
```
Connect wallet → select Ethereum Sepolia → click Request. Receive 10 USDC.

---

## Step 5 — Connect to the Protocol

1. Open the protocol frontend
2. Click **Connect Wallet** in the top right
3. Select your wallet (MetaMask or Phantom)
4. Approve the connection in your wallet extension
5. Make sure your wallet shows **Sepolia** network

You should see your position panel load with zero values.

---

## Step 6 — Deposit WETH Collateral

1. In the **Collateral** panel on the left, make sure **Deposit** tab is selected
2. You will see your WETH balance shown on the right
3. Type the amount you want to deposit (e.g. `0.05`)
4. Click **Deposit WETH**

**First time only:** Your wallet will ask you to **Approve** first. This gives the protocol permission to move your WETH. Click Confirm.

Then it will ask to **Deposit**. Click Confirm again.

Wait for the transaction to confirm (~15 seconds on Sepolia).

Your **Collateral Value** will update showing your deposited WETH priced in USD using Chainlink's live ETH/USD feed.

---

## Step 7 — Borrow USDC

After depositing collateral you have borrowing power.

1. In the **Borrow / Repay** panel on the right, make sure **Borrow** tab is selected
2. Check **Available to Borrow** in your position panel — this is your limit
3. Type an amount to borrow (e.g. `5` for $5 USDC)
4. Click **Borrow USDC**
5. Confirm in your wallet

You now have USDC in your wallet. Your **Outstanding Debt** and **Health Factor** will update.

---

## Understanding Your Position

| Metric | What it means |
|---|---|
| **Collateral Value** | Total USD value of your deposited WETH (Chainlink live price) |
| **Outstanding Debt** | How much USDC you have borrowed + accrued interest |
| **Available to Borrow** | How much more you can borrow (collateral ÷ 1.5 − current debt) |
| **Health Factor** | Safety score of your position |

### Health Factor explained

```
Health Factor = (Collateral USD × 80%) ÷ Total Debt USD

∞       = No debt (safe)
> 1.5   = Very safe (green)
1.0-1.5 = Monitor closely (yellow)
< 1.0   = Liquidatable (red) — act immediately
```

**Example:**
- You deposit 0.05 WETH when ETH = $2,000 → collateral = $100
- You borrow $50 USDC
- Health Factor = ($100 × 80%) ÷ $50 = 1.6 → safe

If ETH drops to $800:
- Collateral = $40
- Health Factor = ($40 × 80%) ÷ $50 = 0.64 → liquidatable

---

## Step 8 — Repay USDC Debt

Repaying reduces your debt and improves your health factor.

1. Make sure you have USDC in your wallet
2. In the **Borrow / Repay** panel, click **Repay** tab
3. Type the amount to repay
4. Click **Repay USDC**
5. **First time:** Approve USDC spending, then confirm repayment
6. Confirm in your wallet

Your debt decreases and health factor improves.

---

## Step 9 — Withdraw Collateral

You can withdraw collateral as long as your position stays healthy after withdrawal.

1. In the **Collateral** panel, click **Withdraw** tab
2. Type the amount to withdraw
3. Click **Withdraw WETH**
4. Confirm in your wallet

If you have debt, withdrawing too much will revert — the protocol protects you from accidentally making your position unhealthy.

---

## Liquidations

If your health factor drops below 1.0, anyone can liquidate your position.

**What happens during liquidation:**
- The liquidator repays part of your USDC debt
- In exchange they receive your WETH collateral at a 10% discount
- Your debt decreases and your position may become healthy again

**How to avoid liquidation:**
- Monitor your health factor regularly
- Repay debt if health factor drops below 1.5
- Add more collateral if ETH price drops significantly
- Don't borrow close to your maximum limit

**The safe zone:** Keep your health factor above 1.5 to have a comfortable buffer against price movements.

---

## Protocol Fees & Rates

| Parameter | Value |
|---|---|
| Collateral Ratio | 150% (borrow max 66% of collateral value) |
| Liquidation Threshold | 80% |
| Liquidation Bonus | 10% (liquidator discount) |
| Borrow APR | 5% annual |
| Protocol fee | None |
| Withdrawal fee | None |

Interest accrues every second. Your debt grows slowly over time even if you do nothing.

---

## Frequently Asked Questions

**Q: Is my collateral safe?**
The protocol is non-custodial — your WETH is held in a smart contract vault controlled by program logic. No admin key can drain your funds. The contracts are verified on Etherscan and open-source.

**Q: What happens if ETH price crashes?**
Your collateral value drops. If your health factor drops below 1.0, liquidators can close your position. To protect yourself: borrow conservatively and monitor your health factor.

**Q: Can I lose more than I deposit?**
No. Worst case: you lose your collateral to liquidation but keep the borrowed USDC. You cannot owe more than your collateral is worth.

**Q: Why is this on Sepolia testnet?**
This is a portfolio/demo project. All tokens have no real value. Do not send real ETH or real USDC.

**Q: How is the ETH price determined?**
By Chainlink's ETH/USD price feed on Sepolia — a decentralised oracle network that aggregates prices from multiple sources and updates every hour or when price moves more than 0.5%.

**Q: What is WETH?**
Wrapped ETH — an ERC20 token that is 1:1 equivalent to ETH. The protocol requires ERC20 tokens for collateral so you wrap ETH into WETH first.

---

## Troubleshooting

**Transaction keeps loading / not confirming**
- Check MetaMask/Phantom for a pending transaction notification
- Make sure you are on Sepolia network
- Check you have enough Sepolia ETH for gas

**Borrow fails**
- Check you have deposited collateral first
- Check Available to Borrow is greater than zero
- Check the protocol has USDC liquidity

**Withdraw fails**
- You may have debt — withdrawing would make your position unhealthy
- Repay some debt first, then try withdrawing

**Health factor shows ∞**
- This is correct — it means you have no debt
- Infinity = perfectly safe

---

## Support & Resources

- Etherscan (view transactions): https://sepolia.etherscan.io
- Sepolia ETH faucet: https://sepoliafaucet.com
- USDC faucet: https://faucet.circle.com
- Chainlink price feeds: https://data.chain.link

---

*This protocol is deployed on Sepolia testnet for demonstration purposes. All tokens are test tokens with no real value.*

# Developer Guide — DeFi Lending Protocol

A complete guide to setting up, building, testing, and extending the protocol locally.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Foundry | Latest | `curl -L https://foundry.paradigm.xyz \| bash` |
| Node.js | 18+ | https://nodejs.org |
| Git | Any | `sudo apt install git` |

---

## Project Structure

```
defi-lending-protocol-full/
│
├── contracts/                  ← Solidity smart contracts (Foundry)
│   ├── src/
│   │   ├── LendingPool.sol         ← User entry point
│   │   ├── CollateralManager.sol   ← Tracks deposits
│   │   ├── BorrowEngine.sol        ← Tracks debt + interest
│   │   ├── LiquidationEngine.sol   ← Handles liquidations
│   │   ├── PriceOracle.sol         ← Chainlink price feeds
│   │   ├── interfaces/             ← AggregatorV3Interface
│   │   ├── libraries/              ← LendingConstants
│   │   └── mocks/                  ← MockUSDC, MockWETH, MockWBTC, MockV3Aggregator
│   ├── test/
│   │   ├── unit/                   ← Unit tests per contract
│   │   ├── integration/            ← Full user journey tests
│   │   └── invariant/              ← Protocol-wide invariant tests
│   ├── script/
│   │   ├── Deploy.s.sol            ← Full deployment script
│   │   ├── HelperConfig.s.sol      ← Network config (Anvil vs Sepolia)
│   │   └── Interact.s.sol          ← Post-deploy interaction script
│   └── foundry.toml
│
└── frontend/                   ← Next.js 14 frontend
    ├── app/
    │   ├── page.tsx                ← Main dashboard page
    │   ├── layout.tsx              ← Root layout with providers
    │   └── providers.tsx           ← wagmi + RainbowKit providers
    ├── components/
    │   ├── Navbar.tsx              ← Wallet connect button
    │   ├── PositionPanel.tsx       ← Live position display
    │   ├── CollateralPanel.tsx     ← Deposit / Withdraw WETH
    │   ├── BorrowPanel.tsx         ← Borrow / Repay USDC
    │   ├── ProtocolStats.tsx       ← Protocol-wide stats
    │   └── Toast.tsx               ← Transaction notifications
    ├── hooks/
    │   ├── usePosition.ts          ← Reads getUserPosition from LendingPool
    │   └── useTokenBalance.ts      ← Reads token balances and allowances
    └── lib/
        ├── addresses.ts            ← Deployed contract addresses
        ├── abis.ts                 ← Contract ABIs
        ├── wagmi.ts                ← wagmi + RainbowKit config
        └── utils.ts                ← Format helpers
```

---

## Smart Contracts Setup

### 1. Clone and install

```bash
git clone https://github.com/sivajisj/defi-lending-protocol
cd defi-lending-protocol-full/contracts
forge install
```

### 2. Configure environment

```bash
cp .env.example .env
```

Edit `.env`:
```bash
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0xYOUR_PRIVATE_KEY
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_KEY
```

Load variables:
```bash
source .env
```

### 3. Build contracts

```bash
forge build
```

### 4. Run all tests

```bash
# All tests
forge test -v

# Unit tests only
forge test --match-path "test/unit/*" -v

# Integration tests only
forge test --match-path "test/integration/*" -v

# Invariant tests only (slower — runs 25,000 sequences)
forge test --match-path "test/invariant/*" -vv

# Specific test file
forge test --match-path "test/unit/PriceOracleTest.t.sol" -v

# Gas report
forge test --gas-report
```

### 5. Test results

| Suite | Tests |
|---|---|
| MocksTest | 12 |
| PriceOracleTest | 23 |
| CollateralManagerTest | 29 |
| BorrowEngineTest | 22 |
| LendingPoolTest | 20 |
| LiquidationEngineTest | 18 |
| UpgradeTest | 13 |
| InvariantTest | 8 invariants × 25,000 sequences |
| **Total** | **145+** |

---

## Protocol Architecture

```
User
 │
 └──► LendingPool.sol          ← Single entry point (UUPS upgradeable)
           │
           ├──► CollateralManager.sol   ← Holds and tracks WETH/WBTC deposits
           │         └──► PriceOracle.sol   ← Chainlink ETH/USD, BTC/USD feeds
           │
           ├──► BorrowEngine.sol        ← Tracks debt, accrues interest
           │         └──► CollateralManager (reads collateral value)
           │
           └──► LiquidationEngine.sol  ← Closes undercollateralised positions
                     └──► PriceOracle + CollateralManager + BorrowEngine
```

### Protocol parameters

| Parameter | Value | Meaning |
|---|---|---|
| Collateral Ratio | 150% | Must deposit $150 to borrow $100 |
| Liquidation Threshold | 80% | Liquidatable when debt > 80% of collateral |
| Liquidation Bonus | 10% | Liquidator gets 10% discount on seized collateral |
| Borrow APR | 5% | Annual interest rate on borrowed USDC |
| Price Feed Timeout | 3600s | Reject Chainlink prices older than 1 hour |
| Min Health Factor | 1.0 | Below this = liquidatable |

---

## Deploy to Sepolia

### 1. Get Sepolia ETH
```
https://sepoliafaucet.com
```

### 2. Run deployment script

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### 3. Save deployed addresses

```bash
cat broadcast/Deploy.s.sol/11155111/run-latest.json | \
  python3 -c "
import json,sys
data = json.load(sys.stdin)
for tx in data['transactions']:
    if tx['transactionType'] == 'CREATE':
        print(tx.get('contractName','unknown'), '->', tx['contractAddress'])
"
```

### 4. Seed USDC liquidity (required for borrowing)

```bash
# Get USDC from Circle faucet: https://faucet.circle.com
# Then approve and deposit:

cast send USDC_ADDRESS \
  "approve(address,uint256)" BORROW_ENGINE_ADDRESS 10000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

cast send BORROW_ENGINE_ADDRESS \
  "depositLiquidity(uint256)" 10000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

## Upgrade a contract (UUPS)

All contracts are UUPS upgradeable. To upgrade PriceOracle:

```bash
# 1. Deploy new implementation
forge create src/PriceOracleV2.sol:PriceOracleV2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 2. Upgrade proxy to point at new implementation
cast send ORACLE_PROXY_ADDRESS \
  "upgradeToAndCall(address,bytes)" NEW_IMPL_ADDRESS 0x \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

State is preserved — only the logic changes. The proxy address never changes.

---

## Frontend Setup

### 1. Install dependencies

```bash
cd frontend
npm install
```

### 2. Configure environment

```bash
cp .env.local.example .env.local
```

Edit `.env.local`:
```bash
NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=your_walletconnect_project_id
```

Get a free Project ID at: https://cloud.walletconnect.com

### 3. Update contract addresses

If you deployed new contracts, update `lib/addresses.ts`:

```typescript
export const ADDRESSES = {
  lendingPool:       "0x...",
  collateralManager: "0x...",
  borrowEngine:      "0x...",
  liquidationEngine: "0x...",
  priceOracle:       "0x...",
  weth:              "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
  wbtc:              "0x29f2D40B0605204364af54EC677bD022dA425d03",
  usdc:              "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
} as const
```

### 4. Run development server

```bash
npm run dev
```

Open http://localhost:3000

### 5. Deploy frontend to Vercel

```bash
npm install -g vercel
vercel env add NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID
vercel --prod
```

---

## Adding a new collateral token

### Step 1 — Add to PriceOracle

```bash
cast send ORACLE_PROXY_ADDRESS \
  "addCollateral(address,address)" \
  NEW_TOKEN_ADDRESS \
  CHAINLINK_FEED_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### Step 2 — Whitelist in LendingPool

```bash
cast send LENDING_POOL_ADDRESS \
  "addCollateralToken(address)" \
  NEW_TOKEN_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### Step 3 — Add to frontend

In `lib/addresses.ts` add the new token address.
In `components/CollateralPanel.tsx` add the token to the UI selector.

---

## Key design decisions

**Why UUPS over Transparent Proxy?**
UUPS stores the upgrade logic in the implementation, not the proxy. This reduces proxy deployment cost and makes the upgrade surface smaller. `_authorizeUpgrade` with `onlyOwner` is the single security gate.

**Why separate CollateralManager from LendingPool?**
Single responsibility. Auditors can review collateral accounting independently. BorrowEngine can read collateral values without touching transfer logic.

**Why simple interest over compound?**
Compound interest requires exponentiation (`(1+r)^t`) which is expensive on-chain. Simple interest per-second is accurate enough for reasonable loan durations and is the standard approach for EVM lending protocols.

**Why CEI pattern everywhere?**
Checks-Effects-Interactions prevents reentrancy at the logic level. ReentrancyGuard prevents it at the mechanical level. Both together means two independent layers of defence.

---

## Chainlink feed addresses (Sepolia)

| Pair | Address |
|---|---|
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| BTC/USD | `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` |
| LINK/USD | `0xc59E3633BAAC79493d908e63626716e204A45EdF` |

---

## Useful cast commands

```bash
# Check position
cast call LENDING_POOL "getUserPosition(address)(uint256,uint256,uint256,bool)" YOUR_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# Check health factor
cast call BORROW_ENGINE "getHealthFactor(address)(uint256)" YOUR_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# Check available liquidity
cast call BORROW_ENGINE "getAvailableLiquidity()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Check ETH price from Chainlink
cast call 0x694AA1769357215DE4FAC081bf1f309aDC325306 "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $SEPOLIA_RPC_URL

# Check borrow index
cast call BORROW_ENGINE "getBorrowIndex()(uint256)" --rpc-url $SEPOLIA_RPC_URL
```

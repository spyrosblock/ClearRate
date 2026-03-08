# ClearRate


## Table of Contents

- [ClearRate](#clearrate)
  - [Table of Contents](#table-of-contents)
  - [🚀 Overview](#-overview)
  - [What Problem Does It Solve?](#what-problem-does-it-solve)
  - [Why ClearRate Outperforms Traditional Clearinghouses](#why-clearrate-outperforms-traditional-clearinghouses)
  - [Why ClearRate Uses Chainlink CRE](#why-clearrate-uses-chainlink-cre)
  - [✨ Key Features](#-key-features)
  - [🏗️ Architecture](#️-architecture)
  - [📂 Project Structure](#-project-structure)
  - [🛠️ Installation](#️-installation)
    - [Prerequisites](#prerequisites)
    - [Quick Start](#quick-start)
  - [📋 Usage](#-usage)
    - [Lifecycle Commands](#lifecycle-commands)
    - [Read Commands](#read-commands)
    - [Utility Commands](#utility-commands)
  - [🛡️ Core Smart Contracts](#️-core-smart-contracts)
    - [ClearingHouse.sol](#clearinghousesol)
    - [IRSInstrument.sol](#irsinstrumentsol)
    - [MarginVault.sol](#marginvaultsol)
    - [RiskEngine.sol](#riskenginesol)
    - [Whitelist.sol](#whitelistsol)
    - [LiquidationEngine.sol](#liquidationenginesol)
  - [🔄 CRE Workflows](#-cre-workflows)
    - [1. Whitelist User Workflow](#1-whitelist-user-workflow)
    - [2. Create Trade Workflow](#2-create-trade-workflow)
    - [3. Settle VM Workflow](#3-settle-vm-workflow)
    - [4. Liquidation Workflow](#4-liquidation-workflow)
    - [5. Store Logs Workflow](#5-store-logs-workflow)
  - [📊 Database Schema](#-database-schema)
    - [`swap_positions`](#swap_positions)
    - [`users`](#users)
    - [`liquidation_monitoring`](#liquidation_monitoring)
  - [Files That Use Chainlink](#files-that-use-chainlink)
  - [🧪 Testing](#-testing)
    - [Run Contract Tests](#run-contract-tests)
    - [Test Coverage](#test-coverage)
  - [🔒 Security Considerations](#-security-considerations)
    - [Audit Status](#audit-status)
    - [Known Considerations](#known-considerations)
  - [🤝 Contributing](#-contributing)
  - [📄 License](#-license)
  - [📞 Contact](#-contact)

---

## 🚀 Overview

ClearRate is a decentralized Central Counterparty (CCP) for **Interest Rate Swaps (IRS)** — bringing institutional-grade derivatives clearing to blockchain. Similar to traditional clearinghouses like CME or LCH, ClearRate acts as the central counterparty for all IRS trades, but operates fully on-chain with enhanced transparency, efficiency, and flexibility.

When two parties agree on a trade, ClearRate **novates** the trade, becoming the buyer to every seller and the seller to every buyer. This eliminates bilateral counterparty risk and ensures positions are accurately collateralized and settled.

---

## What Problem Does It Solve?

More than half a **Quadrillion dollars** ($500+ trillion) of interest rate swaps flow through a handful of clearinghouses that are **opaque, slow, expensive, and centralized**. This creates systemic vulnerabilities that threaten the entire financial system.

Traditional OTC derivatives markets face several critical challenges:

| Challenge | ClearRate Solution |
|-----------|-------------------|
| **Systemic Contagion Risk** | A single default is contained within the CCP rather than spreading bilaterally to multiple interconnected firms |
| **Opaque Markets** | On-chain transparency provides real-time visibility into positions, exposures, and activity for all participants |
| **Inefficient Operations** | Settlement in seconds instead of days; netting reduces payments and collateral overhead |
| **"Too Interconnected to Fail"** | Decentralized risk management eliminates single points of failure and reduces systemic threats |
| **Centralized Control** | Permissionless innovation with institutional-grade compliance; no gatekeeper bottlenecks |
| **High Costs** | Dramatic cost reduction by eliminating intermediary fees, legal overhead, and compression services |

---

## Why ClearRate Outperforms Traditional Clearinghouses

| Feature | Traditional CCPs | ClearRate |
|---------|-----------------|-----------|
| **Settlement Speed** | Hours or days | Seconds |
| **Cost** | Legal overhead, compression services, intermediary fees | Significant cost reduction |
| **Collateral Flexibility** | Limited options | Any stablecoin, tokenized treasuries, or RWAs |
| **Liquidity/Transfer** | Complicated portfolio compressions | Transfer all or part of position 24/7 |
| **Transparency** | Periodic reports | Full auditability and real-time transparency |

---

## Why ClearRate Uses Chainlink CRE

ClearRate leverages the **Chainlink Runtime Environment (CRE)** for critical off-chain computations:

- ✅ **Consensus-Verified Data** — API data (DB reads/writes, whitelisting, risk models, settlements) is cryptographically provable to on-chain smart contracts
- ✅ **Real-Time Risk Monitoring** — Enables reliable automation of critical actions like liquidations
- ✅ **Cost Efficiency** — Reduces RPC and indexing costs, saves gas
- ✅ **Robustness** — Eliminates single points of failure

---

## ✨ Key Features

| Feature | Description |
|---------|-------------|
| **Trade Novation** | Securely match and novate IRS trades using EIP-712 signatures |
| **Margin Management** | Automated Initial Margin (IM) locking and Maintenance Margin (MM) monitoring |
| **Daily VM Settlement** | Daily Variation Margin (VM) settlement based on Net Present Value (NPV) changes |
| **Tokenized Positions** | IRS positions represented as ERC-1155 tokens with unique swap terms |
| **Liquidation Engine** | Automated liquidation of under-collateralized accounts with position absorption |
| **Institutional KYB** | Advanced whitelisting and trading limits for institutional participants |
| **Position Transfer** | Transfer all or part of your position to another whitelisted account 24/7 |

---

## 🏗️ Architecture

ClearRate follows a four-layer architecture:

```text
┌─────────────────────────────────────────────────────────────┐
│              Database (Neon, PostgreSQL)                    │
│  • Position tracking    • KYB information                   │
│  • Liquidation monitoring   • Event storage                 │
└─────────────────────────────────────────────────────────────┘
                            │  ▲
                            ▼  │
┌─────────────────────────────────────────────────────────────┐
│                    API Layer (Next.js)                      │
│  • REST endpoints       • Real-time data for workflows      │
│  • Database queries     • Frontend serving                  │
└─────────────────────────────────────────────────────────────┘
                            │  ▲
                            ▼  │
┌─────────────────────────────────────────────────────────────┐
│                    CRE Workflows (Off-chain)                │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐     │
│  │ Whitelist    │ │ Create Trade │ │ Settle VM        │     │
│  │ (KYB/AML)    │ │ (Novation)   │ │ (NPV Updates)    │     │
│  └──────────────┘ └──────────────┘ └──────────────────┘     │
│  ┌──────────────┐ ┌──────────────────────────────────────┐  │
│  │ Liquidation  │ │ Store Logs (Event Indexing)          │  │
│  └──────────────┘ └──────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
         DON-signed Report │  ▲ 
                           ▼  │ Event Logs
┌─────────────────────────────────────────────────────────────┐
│              Smart Contracts (On-chain)                     │
│  ┌─────────────────┐  ┌───────────────┐  ┌─────────────┐    │
│  │  ClearingHouse  │  │ IRSInstrument │  │ MarginVault │    │
│  │  (Central Hub)  │  │ (ERC-1155)    │  │ (Collateral)│    │
│  └─────────────────┘  └───────────────┘  └─────────────┘    │
│                                                             │
│  ┌─────────────────┐  ┌───────────────┐  ┌─────────────┐    │
│  │   RiskEngine    │  │   Whitelist   │  │ Liquidation │    │
│  │  (IM/MM Logic)  │  │ (KYB & Limits)│  │   Engine    │    │
│  └─────────────────┘  └───────────────┘  └─────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## 📂 Project Structure

```text
ClearRate/
├── contracts/                    # Smart contracts (Foundry)
│   ├── src/                      # Contract source files
│   │   ├── core/
│   │   │   ├── ClearingHouse.sol # Central coordinator
│   │   │   └── IRSInstrument.sol # ERC-1155 position tokens
│   │   ├── margin/
│   │   │   ├── MarginVault.sol   # Collateral management
│   │   │   └── RiskEngine.sol    # IM/MM calculations
│   │   ├── access/
│   │   │   └── Whitelist.sol     # KYB & trading limits
│   │   ├── liquidation/
│   │   │   └── LiquidationEngine.sol
│   │   └── interfaces/           # Contract interfaces
│   ├── script/                   # Deployment scripts
│   ├── test/                     # Unit & integration tests
│   └── lib/                      # Dependencies (forge-std, OpenZeppelin)
│
├── whitelist-user-workflow/      # KYB verification & whitelisting
├── create-trade-workflow/        # Trade matching & novation
├── settle-vm-workflow/           # Daily NPV & VM settlement
├── liquidation-workflow/         # Margin monitoring & liquidations
├── store-logs-workflow/          # Event indexing to database
│
├── nextjs/                       # Frontend & API
│   ├── app/                      # Next.js app router
│   ├── lib/                      # Database utilities
│   └── public/                   # Static assets
│
├── tables.sql                    # Database schema
├── project.yaml                  # CRE CLI configuration
├── Makefile                      # Project commands
└── README.md
```

---

## 🛠️ Installation

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Foundry](https://book.getfoundry.sh/getting-started/installation) | Latest | Smart contract development |
| [Bun](https://bun.sh/docs/installation) | Latest | Workflow runtime |
| [Node.js](https://nodejs.org/) | v18+ | Next.js API |
| [cre-cli](https://github.com/smartcontractkit/cre-cli) | Latest | Chainlink CRE CLI |
| [PostgreSQL](https://neon.tech/) | - | Database (Neon recommended) |

### Quick Start

1. **Clone the repository**
   ```bash
   git clone https://github.com/spyrosblock/ClearRate.git
   cd ClearRate
   ```

2. **Install dependencies**
   ```bash
   # Install workflow dependencies
   make workflow-install
   
   # Install Next.js dependencies
   cd nextjs && npm install && cd ..
   
   # Install Foundry dependencies
   cd contracts && forge install && cd ..
   ```

3. **Configure environment variables**
   
   Create `.env` files from the examples:
   ```bash
   # CRE environment (root directory)
   cp env_example .env
   
   # Contracts environment
   cp contracts/.env.example contracts/.env
   
   # Next.js environment (optional)
   cp nextjs/env.local.example nextjs/.env.local
   ```

4. **Configure your settings**
   
   - **Root `.env`**: Add your CRE private key
   - **`contracts/.env`**: Configure API keys, private keys (with Sepolia ETH), and addresses
   - **`nextjs/.env.local`**: Add your PostgreSQL database URL

---

## 📋 Usage

All commands are centralized in the root `Makefile`:

### Lifecycle Commands

| Command | Description |
|---------|-------------|
| `make deploy-contracts` | Deploy contracts to Sepolia testnet |
| `make update-config-addresses` | Update workflow configs with deployed addresses |
| `make whitelist-users` | Whitelist users 1, 2, and 3 via CRE workflow |
| `make deposit-margin` | Mint mock tokens and deposit collateral |
| `make create-trade` | Create a swap via CRE workflow |
| `make settle-vm` | Settle variation margin for all positions |
| `make settle-vm-final` | Final settlement for matured positions |
| `make withdraw-margin` | Withdraw collateral after settlement |
| `make liquidate` | Execute liquidations for undercollateralized accounts |
| `make absorb-positions` | Absorb liquidated positions |
| `make transfer-position` | Transfer position to another account |

### Read Commands

| Command | Description |
|---------|-------------|
| `make get-onchain-data` | Get margin data for all users from chain |
| `make get-db-data` | Get data from the database via API |

### Utility Commands

| Command | Description |
|---------|-------------|
| `make workflow-install` | Install dependencies for all workflows |

---

## 🛡️ Core Smart Contracts

### ClearingHouse.sol

The central coordinator for the protocol:

```solidity
contract ClearingHouse is AccessControl, EIP712, ReceiverTemplate {
    // Core functionality:
    // • Trade novation via EIP-712 signatures
    // • VM settlement processing
    // • Position transfers
    // • Liquidation support
    // • CRE report processing
}
```

**Key Functions:**
- `getTradeDigest()` — Get EIP-712 digest for trade signing
- `transferPosition()` — Transfer position to another account
- `absorbPositions()` — Called by LiquidationEngine during liquidation

### IRSInstrument.sol

ERC-1155 contract for tokenized IRS positions:

```solidity
struct SwapTerms {
    uint256 notional;           // Notional amount
    uint256 fixedRateBps;       // Fixed rate in basis points
    uint256 startDate;          // Swap effective date
    uint256 maturityDate;       // Swap maturity date
    uint256 paymentInterval;    // Payment interval in seconds
    Direction direction;        // PAY_FIXED or RECEIVE_FIXED
    bytes32 floatingRateIndex;  // e.g., SOFR, EURIBOR
    DayCountConvention dayCountConvention;
    address collateralToken;    // Collateral token address
    bool active;                // Position active status
    int256 lastNpv;             // Last mark-to-market NPV
}
```

### MarginVault.sol

Secure collateral management:

- Deposit/withdraw collateral (ERC-20 tokens)
- Lock/release Initial Margin
- Settle Variation Margin (credits and debits)

### RiskEngine.sol

Margin requirement calculations:

- `calculateIM()` — Calculate Initial Margin based on notional and tenor
- `calculateMM()` — Calculate Maintenance Margin
- `checkIM()` — Verify sufficient margin for trade
- `updateMaintenanceMargin()` — Update MM for an account

### Whitelist.sol

Institutional KYB management:

- Account registration and approval
- KYC expiry tracking
- Trading limit enforcement (max notional)
- Account ownership verification

### LiquidationEngine.sol

Automated liquidation handling:

- Start liquidation auctions
- Process position absorption
- Calculate liquidation premiums

---

## 🔄 CRE Workflows

ClearRate uses five CRE workflows for off-chain computation:

### 1. Whitelist User Workflow

| Property | Value |
|----------|-------|
| **Trigger** | HTTP |
| **Purpose** | Execute KYB and set trading limits |
| **Input** | User registration data (company, LEI, documents) |
| **Output** | Account whitelisted with max notional limit |

### 2. Create Trade Workflow

| Property | Values |
|----------|--------|
| **Trigger** | HTTP |
| **Purpose** | Submit matched trades for novation |
| **Input** | EIP-712 signed trade data from both parties |
| **Output** | ERC-1155 position tokens minted, IM locked |

### 3. Settle VM Workflow

| Property | Value |
|----------|-------|
| **Trigger** | Cron (daily) |
| **Purpose** | Calculate NPV changes and settle VM |
| **Process** | Fetch rates → Calculate NPV → Aggregate changes → Submit on-chain |
| **Output** | VM credits/debits applied to accounts |

### 4. Liquidation Workflow

| Property | Value |
|----------|-------|
| **Trigger** | Cron (hourly) |
| **Purpose** | Monitor margin and trigger liquidations |
| **Process** | Check collateral vs MM → Identify undercollateralized → Start auctions |
| **Output** | Liquidation auctions started |

### 5. Store Logs Workflow

| Property | Value |
|----------|-------|
| **Trigger** | Event logs |
| **Purpose** | Index blockchain events to database |
| **Events** | `TradeNovated`, `MarginDeposited`, `MarginWithdrawn`, `PositionTransferred`, `PositionsAbsorbed`, `PositionMatured` |
| **Output** | Database updated with event data |

---

## 📊 Database Schema

ClearRate uses PostgreSQL to track protocol activity:

### `swap_positions`

| Column | Type | Description |
|--------|------|-------------|
| `token_id` | VARCHAR(78) | ERC-1155 token ID |
| `owner_id` | VARCHAR(66) | bytes32 account ID |
| `notional` | NUMERIC | Notional amount |
| `fixed_rate_bps` | INTEGER | Fixed rate in basis points |
| `direction` | INTEGER | 0=PAY_FIXED, 1=RECEIVE_FIXED |
| `active` | BOOLEAN | Position status |
| `last_npv` | NUMERIC | Last mark-to-market NPV |
...

### `users`

| Column | Type | Description |
|--------|------|-------------|
| `address` | VARCHAR(42) | Ethereum address |
| `account_id` | VARCHAR(66) | bytes32 account ID |
| `company_name` | VARCHAR(255) | Company name |
| `lei` | VARCHAR(20) | Legal Entity Identifier |
| `approved` | BOOLEAN | KYB approval status |
| `valid_until` | TIMESTAMPTZ | Approval validity |
| `max_notional` | NUMERIC | Maximum trading limit |
...

### `liquidation_monitoring`

| Column | Type | Description |
|--------|------|-------------|
| `account_id` | VARCHAR(66) | bytes32 account ID |
| `total_collateral` | NUMERIC | Current collateral |
| `maintenance_margin` | NUMERIC | Required MM |
| `collateral_token` | VARCHAR(42) | Token address |

---

## Files That Use Chainlink
- `/create-trade-workflow`
- `/settle-vm-workflow`
- `/store-logs-workflow`
- `/whitelist-user-workflow`
- `/liquidation-workflow`
- `/contracts/src/interfaces/ReceiverTemplate.sol`
- `/contracts/src/assess/Whitelist.sol`
- `/contracts/src/core/ClearingHouse.sol`
- `/contracts/src/liquidation/LiquidationEngine.sol`

---

## 🧪 Testing

### Run Contract Tests

```bash
cd contracts

# Run all tests
forge test

# Run with verbosity
forge test -vvvv

# Run specific test file
forge test --match-path test/ClearingHouseIntegration.t.sol

# Generate gas snapshot
forge snapshot
```

### Test Coverage

```bash
forge coverage
```

---

## 🔒 Security Considerations

### Audit Status

⚠️ **This project is in active development and has not been audited.** Do not use in production with real funds.

### Known Considerations

1. **Signature Replay Protection** — Uses nonces per account to prevent replay attacks
2. **Trade Deduplication** — `tradeSubmitted` mapping prevents double-submission
3. **KYC Expiry** — Positions cannot be created with expired KYC
4. **Margin Checks** — IM verified before trade execution
5. **Whitelist Enforcement** — All participants must be whitelisted

---

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is currently **UNLICENSED**. All rights reserved.

---

## 📞 Contact

- **GitHub**: [spyrosblock/ClearRate](https://github.com/spyrosblock/ClearRate)
- **Issues**: [GitHub Issues](https://github.com/spyrosblock/ClearRate/issues)

---

<div align="center">

**Built with ❤️ using Solidity, Foundry, and Chainlink CRE**

</div>
# ClearRate

ClearRate is a Decentralized Central Counterparty (CCP) for **Interest Rate Swaps (IRS)**. It enables institutional-grade clearing and settlement of swap positions on-chain, using smart contracts, off-chain workflows (CRE), and a robust margin management system.

## 🚀 Overview

ClearRate acts as the central counterparty for all interest rate swap trades. When two parties agree on a trade, ClearRate **novales** the trade, becoming the buyer to every seller and the seller to every buyer. This eliminates bilateral counterparty risk and ensures that positions are accurately collateralized and settled.

### Key Features

- **Trade Novation**: Securely match and novate IRS trades using EIP-712 signatures.
- **Margin Management**: Automated Initial Margin (IM) locking and Maintenance Margin (MM) monitoring.
- **Daily VM Settlement**: Daily Variation Margin (VM) settlement based on Net Present Value (NPV) changes.
- **Tokenized Positions**: IRS positions are represented as ERC-1155 tokens, where each token encapsulates unique swap terms.
- **Liquidation Engine**: Automated liquidation of under-collateralized accounts with position absorption.
- **Institutional KYB**: Advanced whitelisting and Legal Entity Identifier (LEI) tracking for participants.

---

## 🏗️ Architecture

The project consists of three main layers:

1.  **Smart Contracts (Foundry)**: The core protocol logic running on EVM-compatible chains.
2.  **CRE Workflows (Chainlink Runtime Environment)**: Automated off-chain processes that handle complex calculations, rate fetching, and on-chain reporting.
3.  **Database & API (Next.js/PostgreSQL)**: A data layer for tracking positions, KYB information, and providing real-time data to workflows and frontends.

---

## 📂 Project Structure

```text
├── contracts/               # Core Solidity smart contracts (Foundry)
│   ├── src/                 # Contract source files (ClearingHouse, MarginVault, etc.)
│   ├── script/              # Deployment and interaction scripts
│   └── test/                # Unit and integration tests
├── nextjs/                  # Frontend and API (Next.js & Neon PostgreSQL)
│   ├── app/api/             # API routes for data retrieval and DB updates
│   └── lib/                 # Database connection and utilities
├── *-workflow/              # CRE Workflows (TypeScript/Bun)
│   ├── whitelist-user       # Automated KYB and whitelisting
│   ├── create-trade         # Trade matching and novation
│   ├── settle-vm            # Daily NPV update and VM settlement
│   ├── liquidation          # Monitoring and executing liquidations
│   └── store-logs           # Take actions based on event logs
├── tables.sql               # Database schema definitions
├── project.yaml             # CRE CLI project configuration
└── Makefile                 # Centralized command center for the project
```

---

## 🛠️ Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (Smart contract development)
- [Bun](https://bun.sh/docs/installation) (Workflow runtime)
- [Node.js](https://nodejs.org/) (Next.js API)
- `cre-cli` (Chainlink Runtime Environment CLI)
- PostgreSQL (e.g., [Neon](https://neon.tech/))

### Installation

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/spyrosblock/ClearRate.git
    cd ClearRate
    ```

2.  **Install dependencies**:
    ```bash
    make workflow-install
    cd nextjs && npm install
    cd ../contracts && forge install
    ```

3.  **Environment Setup**:
    - Copy `env_example` to `.env` in the root and fill in your CRE private key.
    - Copy `contracts/.env.example` to `contracts/.env` and configure your RPC and deployer keys.
    - Copy `nextjs/env.local.example` to `nextjs/.env.local` and add your database URL.

---

## 📋 Lifecycle & Usage

The project follows a specific lifecycle managed through the root `Makefile`.

1.  **Deploy Contracts**: `make deploy-contracts`
2.  **Whitelist Users**: `make whitelist-users`
3.  **Deposit Margin**: `make deposit-margin` (Mints mock tokens and locks collateral)
4.  **Create Trade**: `make create-trade` (Generates trade JSON and submits to ClearingHouse)
5.  **Daily Settlement**: `make settle-vm` (Updates NPV and settles variation margin)
6.  **Withdraw Margin**: `make withdraw-margin` (After position maturity or settlement)

---

## 🛡️ Core Smart Contracts

- **`ClearingHouse.sol`**: The central coordinator for trade matching, novation, and settlement batch processing.
- **`IRSInstrument.sol`**: An ERC-1155 contract where each token ID represents a unique set of swap terms (notional, rate, maturity, etc.).
- **`MarginVault.sol`**: Securely holds user collateral and manages the locking/releasing of Initial Margin.
- **`RiskEngine.sol`**: Determines the required collateral for positions and monitors account health.
- **`Whitelist.sol`**: Manages approved participants and their trading limits.

---

## 📊 Database Schema

ClearRate uses PostgreSQL to track and index protocol activity:
- `swap_positions`: Detailed records of all minted ERC-1155 swap legs.
- `users`: Participant legal data, KYB status, and LEI information.
- `liquidation_monitoring`: Real-time tracking of account collateral vs. maintenance margin requirements.

---


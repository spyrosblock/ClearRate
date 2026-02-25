---
name: Project Description
---


# DESCRIPTION.md — Onchain Central Counterparty (CCP) for Interest Rate Swaps

## 1. Project Overview

### Purpose
This project implements an **onchain Central Counterparty Clearinghouse (CCP)** for **Interest Rate Swaps (IRS)** — a decentralized financial infrastructure that replicates the role of traditional clearinghouses (like LCH or CME) on blockchain rails. The system handles trade novation, margin management, mark-to-market settlement, portfolio risk netting, and liquidation — all with trust-minimized offchain compute powered by Chainlink.

> **Collateral Model:** The system accepts **stablecoins only** (e.g., USDC, USDT, DAI) as margin collateral. Stablecoins are treated at face value (1:1 with USD) — there are no collateral haircuts or price-feed adjustments for deposited assets.

### Key Technologies
| Layer | Technology | Purpose |
|-------|-----------|---------|
| Smart Contracts | **Solidity 0.8.24** | Core clearing, margin, risk, and settlement logic |
| Development Framework | **Foundry** (forge, cast, anvil) | Compilation, testing, deployment, scripting |
| Offchain Compute | **Chainlink CRE** (TypeScript/Node.js) | Yield curve bootstrapping, VaR/SPAN risk models, NPV calculations |
| Token Standard | **ERC-1155** (OpenZeppelin) | Position representation for novated IRS legs |
| Oracle Infrastructure | **Chainlink Aggregator** | Discount factor and rate oracle delivery |
| Workflows | **Chainlink CRE DON** | Automated VM settlement, trade creation, SOFR fetching |

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     SINGLE CHAIN (Ethereum L1)              │
│                                                             │
│  ┌──────────────┐  ┌─────────────┐  ┌───────────────────┐  │
│  │ ClearingHouse │  │ RiskEngine  │  │   MarginVault     │  │
│  │   .sol        │  │   .sol      │  │      .sol         │  │
│  └──────┬───────┘  └──────┬──────┘  └────────┬──────────┘  │
│         │                 │                   │             │
│  ┌──────┴───────┐  ┌─────┴──────┐  ┌────────┴──────────┐  │
│  │IRSInstrument │  │Liquidation │  │  InsuranceFund     │  │
│  │   .sol       │  │ Engine.sol │  │      .sol          │  │
│  └──────────────┘  └────────────┘  └───────────────────┘  │
│         │                                                   │
│  ┌──────┴──────────────┐   ┌────────────────────────────┐ │
│  │ YieldCurveOracle.sol│   │   Whitelist.sol             │ │
│  └─────────────────────┘   └─────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
                   ▲
                   │ Offchain Compute
    ┌──────────────┴──────────────┐
    │   CHAINLINK CRE (DON)        │
    │  • SOFR fetching             │
    │  • Yield curve bootstrap     │
    │  • NPV matrix computation    │
    │  • VaR / SPAN simulation     │
    │  • VM settlement             │
    │  • Trade creation            │
    └──────────────────────────────┘
```

---

## 2. Getting Started

### Prerequisites
- **Foundry** (forge >= 0.2.0): [Install Guide](https://book.getfoundry.sh/getting-started/installation)
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```
- **Node.js** (v18+) and npm/yarn — for Chainlink CRE TypeScript workflows
- **Bun** — for running TypeScript workflows (faster than Node.js)
- **Chainlink CRE CLI** — for offchain compute workflow deployment
- **Git** — version control
- **Next.js** — for frontend development

### Installation
```bash
# Navigate to contracts directory
cd contracts

# Install Foundry dependencies (OpenZeppelin, Chainlink)
forge install

# Verify compilation
forge build

# Run all tests
forge test
```

### Running Next.js
```bash
# Navigate to Next.js app
cd nextjs

# Install dependencies
npm install

# Run development server
npm run dev
```

### Key Dependencies (via `foundry.toml` remappings)
| Dependency | Remapping | Purpose |
|-----------|-----------|---------|
| OpenZeppelin Contracts | `@openzeppelin/=lib/openzeppelin-contracts/` | ERC-1155, AccessControl, ReentrancyGuard |
| Chainlink Contracts | `@chainlink/=lib/chainlink/` | AggregatorV3 |

### Running Tests
```bash
# All tests
forge test

# Unit tests only
forge test --match-path "test/Unit/*"

# Verbose output with traces
forge test -vvvv

# Gas report
forge test --gas-report
```

### Deployment
```bash
# Deploy contracts
cd contracts
make deploy
```

### Chainlink CRE Workflow Simulation

```bash
cd create-trade-workflow && bun install
cre workflow simulate . --target staging-settings --broadcast
```

---

## 3. Project Structure

```
├── .clinerules/                     # Project rules and description
│   └── DESCRIPTION.md               # This file
│
├── contracts/                       # Solidity smart contracts
│   ├── src/                         # Contract source code
│   │   ├── core/                    # Core clearing and trade logic
│   │   │   ├── ClearingHouse.sol    # Trade novation, EIP-712 matched trade intake
│   │   │   ├── IRSInstrument.sol    # ERC-1155 position tokens for IRS legs
│   │   │   └── PositionMath.sol      # Pure library: day-count fractions, stub periods, accrual
│   │   ├── margin/                  # Margin and risk management
│   │   │   ├── MarginVault.sol      # Margin ledger per accountId
│   │   │   └── RiskEngine.sol       # IM/MM validation, portfolio margin checks
│   │   ├── oracles/                 # Oracle integrations
│   │   │   └── YieldCurveOracle.sol # Ingests discount factors from Chainlink CRE DON
│   │   ├── liquidation/             # Liquidation mechanics
│   │   │   └── LiquidationEngine.sol # Dutch auction liquidations, position absorption
│   │   ├── insurance/               # Clearinghouse backstop
│   │   │   └── InsuranceFund.sol     # Capital injection when accounts go bankrupt
│   │   ├── access/                  # Access control
│   │   │   └── Whitelist.sol         # KYC/governance-controlled address registry
│   │   └── interfaces/              # Interface definitions
│   │       ├── IERC165.sol
│   │       ├── IReceiver.sol
│   │       └── ReceiverTemplate.sol
│   │
│   ├── script/                      # Foundry deployment scripts
│   │   ├── Deploy.s.sol             # Deploys all contracts
│   │   ├── DepositMargin.s.sol      # Deposit margin script
│   │   ├── WhitelistUsers.s.sol     # Whitelist users script
│   │   └── ClearRateScript.sol      # Base script contract
│   │
│   ├── test/                        # Test suite
│   │   ├── Unit/                     # Unit tests
│   │   │   ├── ClearingHouse.t.sol  # Unit tests for core clearing logic
│   │   │   └── Whitelist.t.sol      # Unit tests for whitelist
│   │   ├── Integration/              # Integration tests
│   │   └── mocks/                    # Mock contracts for testing
│   │       └── ERC20Mock.sol         # Mock ERC20 for testing
│   │
│   ├── foundry.toml                 # Foundry configuration
│   ├── Makefile                     # Build and test shortcuts
│   ├── .env.example                 # Environment variable template
│   └── lib/                         # Dependencies (forge-std, openzeppelin-contracts)
│
├── sofr-rate-workflow/              # Chainlink CRE workflow (SOFR rate fetching)
│   ├── main.ts                      # Main workflow entry point
│   ├── config.staging.json         # Staging configuration
│   ├── config.production.json      # Production configuration
│   ├── workflow.yaml               # Workflow definition
│   └── README.md                    # Workflow documentation
│
├── settle-vm-workflow/              # Chainlink CRE workflow (VM settlement)
│   ├── main.ts                      # Main workflow entry point
│   ├── config.staging.json         # Staging configuration
│   ├── config.production.json      # Production configuration
│   ├── workflow.yaml               # Workflow definition
│   ├── vm-settlement-example.json  # Example settlement payload
│   └── README.md                    # Workflow documentation
│
├── create-trade-workflow/           # Chainlink CRE workflow (Trade creation)
│   ├── main.ts                      # Main workflow entry point
│   ├── config.staging.json         # Staging configuration
│   ├── config.production.json      # Production configuration
│   ├── workflow.yaml               # Workflow definition
│   └── README.md                    # Workflow documentation
│
├── project.yaml                     # Project configuration
├── secrets.yaml                     # Secrets configuration
├── DEMO.md                          # Demo documentation
├── cre_docs.md                      # CRE documentation
└── env_example                      # Environment variables example
```

### Key Files and Roles

| File | Role | Critical Functions |
|------|------|--------------------|
| `ClearingHouse.sol` | Central coordinator | `submitMatchedTrade()`, `novate()`, `compressPositions()`, `settleVM()`, `_processReport()` |
| `IRSInstrument.sol` | Position representation | ERC-1155 mint/burn for IRS legs; stores swap terms (notional, fixed rate, tenor, maturity) |
| `PositionMath.sol` | Math library (pure) | Day-count fraction (ACT/360, 30/360), stub period accrual, PV helpers |
| `MarginVault.sol` | Margin ledger | `updateMargin()`, `getFreeMargin()`, `lockInitialMargin()`, `releaseMargin()` |
| `RiskEngine.sol` | Risk validation | `checkIM()`, `checkMM()`, `updateMaintenanceMargin()`, `isLiquidatable()` |
| `YieldCurveOracle.sol` | Rate oracle | `updateDiscountFactors(bytes)`, `getDiscountFactor(uint256 tenor)` |
| `LiquidationEngine.sol` | Liquidation | `liquidateAccount()`, `absorbPosition()`, Dutch auction pricing |
| `InsuranceFund.sol` | Backstop capital | `injectCapital()`, `claimDeficit()` |
| `Whitelist.sol` | Access control | `addParticipant()`, `removeParticipant()`, `isWhitelisted()` |

### Workflow Key Files

| Workflow | Purpose | Report Type |
|----------|---------|-------------|
| `sofr-rate-workflow/` | Fetches SOFR rates from external APIs | N/A |
| `settle-vm-workflow/` | Settles variation margin for accounts | Type 1 (VM Settlement) |
| `create-trade-workflow/` | Creates new IRS trades via CRE | Type 0 (Trade Submission) |
| `workflow01/` | Generic workflow template | N/A |

### Next.js API Routes

| Endpoint | Purpose |
|----------|---------|
| `GET /api/margin/account` | Get margin account details |
| `GET /api/margin/initial` | Calculate initial margin |
| `GET /api/sofr` | Get current SOFR rate |
| `GET /api/swap/npv` | Calculate swap NPV |
| `GET /api/trades` | List all trades |
| `GET /api/yield-curve` | Get yield curve data |

---

## 4. Development Workflow

### Coding Standards

- **Solidity Version:** `pragma solidity ^0.8.24;` — use the latest stable compiler features
- **Style Guide:** Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- **NatSpec Comments:** All public/external functions MUST have full NatSpec (`@notice`, `@param`, `@return`, `@dev`)
- **Custom Errors:** Use custom errors (`error InsufficientMargin()`) instead of `require` strings for gas efficiency
- **Naming Conventions:**
  - Contracts: PascalCase (`ClearingHouse`)
  - Functions: camelCase (`submitMatchedTrade`)
  - Constants: UPPER_SNAKE (`MAX_LEVERAGE_BPS`)
  - Internal functions: prefixed with `_` (`_validateSignatures`)
  - Storage variables: no prefix, camelCase (`Margins`)
- **Imports:** Use named imports (`import {Contract} from "./path";`)
- **Access Control:** Use OpenZeppelin `AccessControl` roles, not bare `onlyOwner`

### Testing Approach

| Test Type | Location | Strategy |
|-----------|----------|----------|
| **Unit** | `contracts/test/Unit/` | Isolate each contract; mock dependencies; test all branches |
| **Integration** | `contracts/test/Integration/` | Full flow: deposit → trade → novation → VM settlement → exit |
| **Fuzz** | *(not yet implemented)* | Target `PositionMath.sol` — edge cases in day-count, compounding, overflow |
| **Fork** | *(not yet implemented)* | Fork mainnet to test real oracle reads |
| **Invariant** | *(not yet implemented)* | Clearinghouse solvency invariant: `sum(all_margins) >= sum(all_obligations)` |

**Testing best practices:**
- Aim for >95% line coverage on `core/` and `margin/` contracts
- Every math function in `PositionMath.sol` should have dedicated fuzz campaigns
- Use `vm.expectRevert()` for all negative-path tests
- Use `vm.prank()` to simulate multi-actor flows

### Build & Deployment Process

1. **Local Development:** `cd contracts && forge build` → `forge test` → iterate
2. **Testnet Deployment:** Deploy contracts to Ethereum Sepolia
3. **CRE Workflow Testing:** Run locally with `bun install && cre workflow simulate . --target staging-settings --broadcast` in respective workflow directory
4. **Frontend Development:** `cd nextjs && npm run dev`

---

## 5. Key Concepts

### Domain Terminology

| Term | Definition |
|------|-----------|
| **IRS (Interest Rate Swap)** | A derivative where two parties exchange fixed-rate and floating-rate interest payments on a notional amount |
| **Novation** | The CCP interposes itself between buyer and seller — each trader faces the clearinghouse, not each other |
| **Initial Margin (IM)** | Upfront collateral required to open a position; covers potential future exposure |
| **Maintenance Margin (MM)** | Minimum equity threshold; breach triggers liquidation |
| **Variation Margin (VM)** | Daily settlement of unrealized PnL based on mark-to-market |
| **SOFR** | Secured Overnight Financing Rate — the primary USD floating rate benchmark |
| **Discount Factor** | Present-value multiplier derived from the yield curve: `DF(t) = 1 / (1 + r_t)^t` |
| **Yield Curve Bootstrap** | Process of extracting zero-coupon discount factors from market swap rates |
| **SPAN Margin** | Portfolio-based margining that accounts for correlation/netting across positions |
| **Position Compression** | Canceling offsetting positions to free tied-up margin |
| **Dutch Auction** | Liquidation mechanism where the price starts high and decreases until a buyer steps in |
| **Report Type** | Chainlink CRE report identifier (0=Trade, 1=VM Settlement) |

### Core Abstractions

1. **AccountId (`bytes32`):**  identifier for institutional accounts across all chains. Maps to margin balances, positions, and risk parameters.

2. **Position (ERC-1155 Token):** Each novated IRS leg is an ERC-1155 token. Token metadata encodes:
   - Notional amount
   - Fixed rate (bps)
   - Floating rate index (SOFR)
   - Start date, maturity date
   - Pay/Receive direction
   - Day-count convention

3. **Margin Stack:** Hierarchical margin model (stablecoin collateral valued 1:1 with USD):
   ```
   Total Stablecoin Collateral
   └── Locked IM (per position)
   └── Variation Margin buffer
   └── Free Margin (available for new trades)
   ```

4. **CRE Report Types:** Chainlink CRE workflows send encoded reports to the ClearingHouse:
   - `uint8(0)`: MatchedTrade[] - New trade submissions
   - `uint8(1)`: VMSettlement[] - Variation margin settlements

### Design Patterns

| Pattern | Where Used | Why |
|---------|-----------|-----|
| **EIP-712 Signed Structs** | `ClearingHouse.submitMatchedTrade()` | Gas-free trade agreement; onchain verification |
| **Pull-over-Push** | Variation Margin settlement | Users/keepers call `settleVM()` rather than auto-push |
| **Dutch Auction** | `LiquidationEngine.sol` | Fair price discovery under liquidation stress |
| **Library Pattern** | `PositionMath.sol` | Pure math isolated for gas efficiency and testability |
| **Role-Based Access** | All admin functions | OpenZeppelin `AccessControl` with granular roles |
| **Reentrancy Guard** | All vault and settlement functions | Prevents reentrancy attacks on margin operations |
| **Chainlink DON Integration** | All workflows | Trust-minimized offchain computation |

### Critical Math

**Day-Count Fraction (ACT/360):**
$$DCF = \frac{ActualDays}{360}$$
**Present Value of Fixed Leg:**$$PV_{fixed} = \sum_{i=1}^{n} FixedRate \times Notional \times DCF_i \times DF_i$$
**Present Value of Floating Leg:**$$PV_{float} = \sum_{i=1}^{n} ForwardRate_i \times Notional \times DCF_i \times DF_i$$
**Swap NPV (from fixed payer's perspective):**$$NPV = PV_{float} - PV_{fixed}$$
**Initial Margin:**$$IM = |Notional| \times RiskWeight_{tenor} \times Confidence$$

---

## 6. Common Tasks

### Adding a New Swap Tenor
1. Update `YieldCurveOracle.sol` to accept the new tenor in `updateDiscountFactors()`
2. Add corresponding risk weight in `RiskEngine.sol`
3. Update CRE TypeScript workflow to compute NPV for the new tenor
4. Add unit and fuzz tests for the new tenor's math

### Testing a Full Trade Lifecycle (Local)
```bash
# 1. Compile everything
cd contracts
forge build

# 2. Run the full lifecycle unit test
forge test --match-test "test_FullTradeLifecycle" -vvvv

# 3. The test should cover:
#    deposit → whitelist → submitMatchedTrade → novation → settleVM → compressPositions
```

### Adding a New Stablecoin
1. Add the stablecoin token address to the `MarginVault.sol` accepted-tokens list
2. Add unit tests verifying deposit/withdrawal with the new stablecoin


---

## 7. Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `forge build` fails with import errors | Missing dependencies | Run `forge install` then check `remappings.txt` |
| Fork tests timeout | RPC rate limiting | Use a dedicated RPC provider; set `--fork-retry-backoff` |
| Fuzz tests fail intermittently | Edge case in math | Check for overflow near `type(uint256).max`; add bounded assumptions with `vm.assume()` |
| "Insufficient margin" on test trades | IM calculation mismatch | Verify `RiskEngine` risk weights match test setup |
| ERC-1155 transfer reverts | Missing operator approval | Ensure `ClearingHouse` is approved operator on `IRSInstrument` |
| Workflow simulation fails | Missing config or secrets | Check `config.staging.json` and ensure `.env` is set |

### Debugging Tips

1. **Trace failing transactions:**
   ```bash
   cd contracts
   forge test --match-test "test_Failing" -vvvvv
   ```
   The 5th `v` gives full EVM stack traces.

2. **Debug specific transactions:**
   ```bash
   cd contracts
   forge debug --match-test "test_Specific"
   ```

3. **Inspect storage layout:**
   ```bash
   cd contracts
   forge inspect ClearingHouse storage-layout
   ```

4. **Check contract sizes (24KB limit):**
   ```bash
   cd contracts
   forge build --sizes
   ```

5. **Profile gas per function:**
   ```bash
   cd contracts
   forge test --gas-report --match-contract "ClearingHouseTest"
   ```

6. **Debug workflows:**
   ```bash
   cd <workflow-dir>
   cre workflow simulate . --target staging-settings --debug
   ```

---

## 8. References

### Protocol Documentation
- [CME Clearing Overview](https://www.cmegroup.com/clearing.html) — Traditional CCP model reference
- [LCH SwapClear](https://www.lch.com/services/swapclear) — Industry-leading IRS CCP
- [ISDA Documentation](https://www.isda.org/) — Swap standardization and legal frameworks

### Technical References
- [Foundry Book](https://book.getfoundry.sh/) — Comprehensive Foundry documentation
- [Chainlink CRE Docs](https://docs.chain.link/chainlink-functions) — Decentralized offchain compute
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/) — Security-audited base contracts
- [EIP-712](https://eips.ethereum.org/EIPS/eip-712) — Typed structured data signing
- [ERC-1155](https://eips.ethereum.org/EIPS/eip-1155) — Multi-token standard

### Mathematical References
- [SOFR Rate (NY Fed)](https://www.newyorkfed.org/markets/reference-rates/sofr) — Official SOFR publications
- [Interest Rate Swap Valuation](https://www.investopedia.com/articles/investing/052915/how-value-interest-rate-swap.asp) — PV calculation methodology
- [SPAN Margining](https://www.cmegroup.com/clearing/risk-management/span-overview.html) — Portfolio-based margin model

### Security
- [Solidity Security Considerations](https://docs.soliditylang.org/en/latest/security-considerations.html)
- [Smart Contract Weakness Classification (SWC)](https://swcregistry.io/)
- [Trail of Bits — Building Secure Contracts](https://github.com/crytic/building-secure-contracts)

### Stablecoin Token Addresses (Testnet - Sepolia)
- Ethereum Sepolia USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

---

> **📝 Notes:**
> - The project uses `contracts/src/` for source code (not `contracts/`)
> - CRE workflows are located in `sofr-rate-workflow/`, `settle-vm-workflow/`, and `create-trade-workflow/`
> - Frontend API routes are in `nextjs/app/api/`
> - Test directories Fuzz/, Fork/, and Invariant/ are planned but not yet implemented
> - Environment configuration uses `.env` file (see `env_example` for template)

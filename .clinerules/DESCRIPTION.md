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
| Cross-Chain Messaging | **Chainlink CCIP** | Hub ↔ Spoke margin sync and trade intent relay |
| Offchain Compute | **Chainlink CRE** (TypeScript/Node.js) | Yield curve bootstrapping, VaR/SPAN risk models, NPV calculations |
| Token Standard | **ERC-1155** (OpenZeppelin) | Position representation for novated IRS legs |
| Oracle Infrastructure | **Chainlink Aggregator** | Discount factor and rate oracle delivery |

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     HUB CHAIN (Ethereum L1)                 │
│                                                             │
│  ┌──────────────┐  ┌─────────────┐  ┌───────────────────┐  │
│  │ ClearingHouse │  │ RiskEngine  │  │ GlobalMarginVault │  │
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
└──────────────────┬──────────────────────────────────────────┘
                   │ CCIP
    ┌──────────────┴──────────────┐
    │     SPOKE CHAINS (L2s)      │
    │  ┌────────────────────────┐ │
    │  │  CCIPSpokeGateway.sol  │ │
    │  │  LocalMarginVault.sol  │ │
    │  └────────────────────────┘ │
    └─────────────────────────────┘
                   ▲
                   │ Offchain Compute
    ┌──────────────┴──────────────┐
    │   CHAINLINK CRE (DON)        │
    │  • SOFR fetching             │
    │  • Yield curve bootstrap     │
    │  • NPV matrix computation    │
    │  • VaR / SPAN simulation     │
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
- **Chainlink CRE CLI** — for offchain compute workflow deployment
- **Git** — version control

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

### Key Dependencies (via `foundry.toml` remappings)
| Dependency | Remapping | Purpose |
|-----------|-----------|---------|
| OpenZeppelin Contracts | `@openzeppelin/=lib/openzeppelin-contracts/` | ERC-1155, AccessControl, ReentrancyGuard |
| Chainlink Contracts | `@chainlink/=lib/chainlink/` | CCIP Router, CCIPReceiver, AggregatorV3 |

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
# Deploy Hub contracts to Ethereum
cd contracts
forge script script/DeployHub.s.sol --rpc-url $HUB_RPC --broadcast --verify

# Deploy Spoke contracts to L2
forge script script/DeploySpokes.s.sol --rpc-url $SPOKE_RPC --broadcast --verify
```

### Chainlink CRE Workflow Simulation
Run from the **project root directory**:

```bash
cd workflow01 && bun install
cre workflow simulate workflow01 --target staging-settings --broadcast
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
│   │   │   └── PositionMath.sol     # Pure library: day-count fractions, stub periods, accrual
│   │   ├── margin/                  # Margin and risk management
│   │   │   ├── GlobalMarginVault.sol # Hub-chain global margin ledger per accountId
│   │   │   ├── LocalMarginVault.sol  # Spoke-chain stablecoin deposit vault
│   │   │   └── RiskEngine.sol        # IM/MM validation, portfolio margin checks
│   │   ├── crosschain/              # Cross-chain infrastructure
│   │   │   └── CCIPSpokeGateway.sol  # CCIP sender/receiver for Hub ↔ Spoke messaging
│   │   ├── oracles/                 # Oracle integrations
│   │   │   └── YieldCurveOracle.sol  # Ingests discount factors from Chainlink CRE DON
│   │   ├── liquidation/              # Liquidation mechanics
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
│   │   ├── DeployHub.s.sol          # Deploys all Hub-chain contracts
│   │   ├── DeploySpokes.s.sol       # Deploys Spoke-chain contracts
│   │   └── Script.sol                # Base script contract
│   │
│   ├── test/                        # Test suite
│   │   ├── Unit/                     # Unit tests
│   │   │   ├── ClearingHouse.t.sol   # Unit tests for core clearing logic
│   │   │   └── Whitelist.t.sol       # Unit tests for whitelist
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
│   ├── config.staging.json          # Staging configuration
│   ├── config.production.json       # Production configuration
│   ├── workflow.yaml                # Workflow definition
│   └── README.md                     # Workflow documentation
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
| `ClearingHouse.sol` | Central coordinator | `submitMatchedTrade()`, `novate()`, `compressPositions()`, `settleVM()` |
| `IRSInstrument.sol` | Position representation | ERC-1155 mint/burn for IRS legs; stores swap terms (notional, fixed rate, tenor, maturity) |
| `PositionMath.sol` | Math library (pure) | Day-count fraction (ACT/360, 30/360), stub period accrual, PV helpers |
| `GlobalMarginVault.sol` | Hub margin ledger | `updateMargin()`, `getFreeMargin()`, `lockInitialMargin()`, `releaseMargin()` |
| `LocalMarginVault.sol` | Spoke deposit vault | `depositCollateral()`, `withdrawCollateral()` |
| `RiskEngine.sol` | Risk validation | `checkIM()`, `checkMM()`, `updateMaintenanceMargin()`, `isLiquidatable()` |
| `CCIPSpokeGateway.sol` | Cross-chain bridge | `_ccipSend()`, `_ccipReceive()`, margin sync message encoding |
| `YieldCurveOracle.sol` | Rate oracle | `updateDiscountFactors(bytes)`, `getDiscountFactor(uint256 tenor)` |
| `LiquidationEngine.sol` | Liquidation | `liquidateAccount()`, `absorbPosition()`, Dutch auction pricing |
| `InsuranceFund.sol` | Backstop capital | `injectCapital()`, `claimDeficit()` |
| `Whitelist.sol` | Access control | `addParticipant()`, `removeParticipant()`, `isWhitelisted()` |

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
  - Storage variables: no prefix, camelCase (`globalMargins`)
- **Imports:** Use named imports (`import {Contract} from "./path";`)
- **Access Control:** Use OpenZeppelin `AccessControl` roles, not bare `onlyOwner`

### Testing Approach

| Test Type | Location | Strategy |
|-----------|----------|----------|
| **Unit** | `contracts/test/Unit/` | Isolate each contract; mock dependencies; test all branches |
| **Fuzz** | *(not yet implemented)* | Target `PositionMath.sol` — edge cases in day-count, compounding, overflow |
| **Fork** | *(not yet implemented)* | Fork mainnet/L2 to test real CCIP router interactions and oracle reads |
| **Integration** | *(not yet implemented)* | Full flow: deposit → trade → novation → VM settlement → exit |
| **Invariant** | *(not yet implemented)* | Clearinghouse solvency invariant: `sum(all_margins) >= sum(all_obligations)` |

**Testing best practices:**
- Aim for >95% line coverage on `core/` and `margin/` contracts
- Every math function in `PositionMath.sol` should have dedicated fuzz campaigns
- Use `vm.expectRevert()` for all negative-path tests
- Use `vm.prank()` to simulate multi-actor flows

### Build & Deployment Process

1. **Local Development:** `cd contracts && forge build` → `forge test` → iterate
2. **Testnet Deployment:** Deploy Hub to Sepolia, Spoke to Arbitrum Sepolia and Base Sepolia
3. **CCIP Testing:** Use Chainlink CCIP testnet lanes for cross-chain message verification
4. **CRE Workflow Testing:** Run locally with `npm run simulate` in `sofr-rate-workflow/`
5. **Mainnet:** Deploy via multisig-controlled scripts with `--verify` flag

### Contribution Guidelines
1. Branch from `main` — use `feat/`, `fix/`, `refactor/` prefixes
2. All PRs require passing `forge test` and `forge snapshot` diff
3. New contracts must include corresponding unit test files
4. Significant math changes require updated fuzz test campaigns
5. Gas snapshots must be compared — regressions require justification

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

### Core Abstractions

1. **AccountId (`bytes32`):** Global identifier for institutional accounts across all chains. Maps to margin balances, positions, and risk parameters.

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

4. **Cross-Chain Message Types:** CCIP messages carry typed payloads:
   - `MARGIN_SYNC` — margin deposit/withdrawal updates
   - `TRADE_INTENT` — cross-chain trade submission
   - `LIQUIDATION_NOTICE` — cross-chain liquidation triggers

### Design Patterns

| Pattern | Where Used | Why |
|---------|-----------|-----|
| **Hub-Spoke** | Overall architecture | Centralizes risk on L1; users interact on cheap L2s |
| **EIP-712 Signed Structs** | `ClearingHouse.submitMatchedTrade()` | Gas-free trade agreement; onchain verification |
| **Pull-over-Push** | Variation Margin settlement | Users/keepers call `settleVM()` rather than auto-push |
| **Dutch Auction** | `LiquidationEngine.sol` | Fair price discovery under liquidation stress |
| **Library Pattern** | `PositionMath.sol` | Pure math isolated for gas efficiency and testability |
| **Role-Based Access** | All admin functions | OpenZeppelin `AccessControl` with granular roles |
| **Reentrancy Guard** | All vault and settlement functions | Prevents reentrancy attacks on margin operations |

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
1. Add the stablecoin token address to the `LocalMarginVault.sol` accepted-tokens list
2. Update `GlobalMarginVault.sol` to track the new stablecoin's margin balance
3. Add unit tests verifying deposit/withdrawal with the new stablecoin

### Deploying a New Spoke Chain
1. Copy and configure `CCIPSpokeGateway.sol` with the new chain's CCIP router address
2. Deploy `LocalMarginVault.sol` on the new spoke
3. Register the spoke gateway address on the Hub's `ClearingHouse.sol`
4. Configure CCIP lane selectors in `DeploySpokes.s.sol`
5. Test with fork tests pointing at the new chain's fork

### Updating CRE Offchain Workflow
```bash
# 1. Navigate to the workflow directory
cd workflow01

# 2. Install dependencies
bun install

# 3. Test locally
cre workflow simulate workflow01 --target staging-settings --broadcast

```

### Running Gas Snapshots
```bash
# Generate gas snapshot
cd contracts
forge snapshot

# Compare against previous
forge snapshot --diff .gas-snapshot
```

---

## 7. Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `forge build` fails with import errors | Missing dependencies | Run `forge install` then check `remappings.txt` |
| CCIP fork tests timeout | RPC rate limiting | Use a dedicated RPC provider; set `--fork-retry-backoff` |
| Fuzz tests fail intermittently | Edge case in math | Check for overflow near `type(uint256).max`; add bounded assumptions with `vm.assume()` |
| "Insufficient margin" on test trades | IM calculation mismatch | Verify `RiskEngine` risk weights match test setup |
| ERC-1155 transfer reverts | Missing operator approval | Ensure `ClearingHouse` is approved operator on `IRSInstrument` |
| CCIP message not received in fork test | Wrong chain selector | Verify CCIP chain selectors match testnet/mainnet values |

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

---

## 8. References

### Protocol Documentation
- [CME Clearing Overview](https://www.cmegroup.com/clearing.html) — Traditional CCP model reference
- [LCH SwapClear](https://www.lch.com/services/swapclear) — Industry-leading IRS CCP
- [ISDA Documentation](https://www.isda.org/) — Swap standardization and legal frameworks

### Technical References
- [Foundry Book](https://book.getfoundry.sh/) — Comprehensive Foundry documentation
- [Chainlink CCIP Docs](https://docs.chain.link/ccip) — Cross-chain interoperability protocol
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

### CCIP Addresses (Testnet)
For ethereum sepolia:
- router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59
- chain selector: 16015286601757825753
- rmn: 0xba3f6251de62dED61Ff98590cB2fDf6871FbB991
- token admin registry: 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82
- registry module owner: 0x62e731218d0D47305aba2BE3751E7EE9E5520790
- onramp address for base sepolia: 0x23a5084Fa78104F3DF11C63Ae59fcac4f6AD9DeE
- onramp address for arbitrum sepolia: 0xBc09627e58989Ba8F1eDA775e486467d2A00944F
- offramp address for base sepolia: 0x0820f975ce90EE5c508657F0C58b71D1fcc85cE0
- offramp address for arbitrum sepolia: 0xD2f5edfD4561d6E7599F6c6888Bd353cAFd0c55E

For base sepolia:
- router: 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93
- chain selector: 10344971235874465080
- rmn: 0x99360767a4705f68CcCb9533195B761648d6d807
- token admin registry: 0x736D0bBb318c1B27Ff686cd19804094E66250e17
- registry module owner: 0x8A55C61227f26a3e2f217842eCF20b52007bAaBe
- onramp address for ethereum sepolia: 0x28A025d34c830BF212f5D2357C8DcAB32dD92A20
- offramp address for ethereum sepolia: 0xF4EbCC2c077d3939434C7Ab0572660c5A45e4df5

For arbitrum sepolia:
- router: 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165
- chain selector: 3478487238524512106
- rmn: 0x9527E2d01A3064ef6b50c1Da1C0cC523803BCFF2
- token admin registry: 0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f
- registry module owner: 0xE625f0b8b0Ac86946035a7729Aba124c8A64cf69
- onramp address for ethereum sepolia: 0x64d78F20aD987c7D52FdCB8FB0777bD00de53210
- offramp address for ethereum sepolia: 0xBed6e9131916d724418C8a6FE810F727302a5c00


### Stablecoin Token Addresses (Testnet)
- Ethereum Sepolia USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
- Base Sepolia USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
- Arbitrum Sepolia USDC: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d

---

> **📝 Notes:**
> - The project uses `contracts/src/` for source code (not `contracts/`)
> - CRE workflows are located in `sofr-rate-workflow/`
> - Test directories Fuzz/, Fork/, Integration/, and Invariant/ are planned but not yet implemented
> - Environment configuration uses `.env` file (see `env_example` for template)

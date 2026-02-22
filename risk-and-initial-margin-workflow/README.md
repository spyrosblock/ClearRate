# SOFR Rate Fetching Workflow

A Chainlink CRE workflow that fetches the **Secured Overnight Financing Rate (SOFR)** from the NY Fed Markets API, bootstraps a yield curve by computing discount factors for standard IRS tenor buckets, and writes the results onchain to the `YieldCurveOracle.sol` contract.

## What This Workflow Does

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────────┐
│  1. Fetch SOFR Rate  │ ──▶ │  2. Bootstrap Yield  │ ──▶ │  3. Write Onchain        │
│  (NY Fed API)        │     │     Curve            │     │  (YieldCurveOracle.sol)  │
│                      │     │                      │     │                          │
│  • Spot SOFR rate    │     │  • Compute DFs for   │     │  • Signed report via     │
│  • 30/90/180-day avg │     │    10 tenor buckets  │     │    KeystoneForwarder     │
│  • SOFR Index        │     │  • DF(t) = 1/(1+r)^t │     │  • updateDiscountFactors │
└─────────────────────┘     └─────────────────────┘     └─────────────────────────┘
```

### Tenor Buckets

The workflow computes discount factors for these standard IRS tenors:

| Tenor | Duration (seconds) | Description |
|-------|--------------------|-------------|
| 1M    | 2,592,000          | 30 days     |
| 3M    | 7,776,000          | 90 days     |
| 6M    | 15,552,000         | 180 days    |
| 1Y    | 31,536,000         | 365 days    |
| 2Y    | 63,072,000         | 730 days    |
| 3Y    | 94,608,000         | 1095 days   |
| 5Y    | 157,680,000        | 1825 days   |
| 7Y    | 220,752,000        | 2555 days   |
| 10Y   | 315,360,000        | 3650 days   |
| 30Y   | 946,080,000        | 10950 days  |

### Data Source

**NY Fed Markets API**: `https://markets.newyorkfed.org/api/rates/secured/sofr/last/1.json`

This is the official SOFR publication from the Federal Reserve Bank of New York. The API returns:
- **Spot SOFR rate** (overnight rate)
- **Average rates** (30-day, 90-day, 180-day)
- **SOFR Index** (compounding index)

## Prerequisites

- **Bun** (v1.2.21+): [Install Bun](https://bun.com)
- **CRE CLI**: [Installation Guide](https://docs.chain.link/cre/getting-started/cli-installation)
- **CRE Account**: [Create Account](https://cre.chain.link)

## Setup

### 1. Install dependencies

```bash
cd sofr-rate-workflow && bun install
```

### 2. Configure contract addresses

Edit `config.staging.json` and replace the placeholder addresses:

```json
{
  "evms": [
    {
      "yieldCurveOracleAddress": "<YOUR_YIELD_CURVE_ORACLE_ADDRESS>",
      "proxyAddress": "<YOUR_PROXY_CONTRACT_ADDRESS>",
      "chainSelectorName": "ethereum-testnet-sepolia",
      "gasLimit": "1000000"
    }
  ]
}
```

- **`yieldCurveOracleAddress`**: The deployed `YieldCurveOracle.sol` contract address
- **`proxyAddress`**: The proxy/forwarder contract that receives CRE signed reports

### 3. Configure RPC (if needed)

Ensure `project.yaml` at the project root has an RPC endpoint for your target chain:

```yaml
staging-settings:
  rpcs:
    - chain-name: ethereum-testnet-sepolia
      url: https://ethereum-sepolia-rpc.publicnode.com
```

### 4. Set your private key

Ensure your `.env` file at the project root contains:

```bash
CRE_ETH_PRIVATE_KEY=<your-64-char-hex-private-key>
```

## Simulate the Workflow

Run from the **project root directory**:

```bash
cre workflow simulate sofr-rate-workflow --target staging-settings
```

or to write to contracts

```bash
cre workflow simulate sofr-rate-workflow --target staging-settings --broadcast
```


### Expected Output

```
Workflow compiled

[USER LOG] === SOFR Rate Fetching Workflow Started ===
[USER LOG] Fetching SOFR rate from: https://markets.newyorkfed.org/api/rates/secured/sofr/last/1.json
[USER LOG] SOFR Rate: 4.30% (effective: 2026-02-20)
[USER LOG] Bootstrapping yield curve from SOFR data...
[USER LOG]   1M: DF = 996487671232876712 (99.648767%)
[USER LOG]   3M: DF = 989502762430939226 (98.950276%)
[USER LOG]   ...
[USER LOG] Writing discount factors to YieldCurveOracle...
[USER LOG] === SOFR Rate Fetching Workflow Completed ===
```

## Configuration

### Schedule

The cron schedule in config files controls how often the workflow runs:

| Schedule | Description |
|----------|-------------|
| `0 0 */6 * * *` | Every 6 hours (default) |
| `0 0 8 * * *` | Daily at 8:00 AM UTC |
| `0 */30 * * * *` | Every 30 minutes |

### Config Schema

| Field | Type | Description |
|-------|------|-------------|
| `schedule` | string | Cron expression for trigger frequency |
| `sofrApiUrl` | string | Primary NY Fed SOFR API endpoint |
| `sofrApiBackupUrl` | string (optional) | Backup API endpoint |
| `evms[].yieldCurveOracleAddress` | string | YieldCurveOracle contract address |
| `evms[].proxyAddress` | string | Proxy contract for CRE report delivery |
| `evms[].chainSelectorName` | string | Target chain name |
| `evms[].gasLimit` | string | Gas limit for write transactions |

## Architecture

This workflow is part of the ClearRate CCP system's offchain compute layer:

```
┌─────────────────────────────────────────────────────┐
│               CRE DON (Workflow DON)                │
│                                                     │
│  ┌─────────────┐   ┌──────────────┐                │
│  │ Cron Trigger │──▶│ SOFR Workflow │                │
│  │ (every 6h)   │   │              │                │
│  └─────────────┘   │ 1. Fetch SOFR│                │
│                     │ 2. Bootstrap │                │
│                     │ 3. Write     │                │
│                     └──────┬───────┘                │
│                            │ signed report          │
└────────────────────────────┼────────────────────────┘
                             ▼
                 ┌───────────────────────┐
                 │  KeystoneForwarder    │
                 │  (signature verify)   │
                 └───────────┬───────────┘
                             ▼
                 ┌───────────────────────┐
                 │  YieldCurveOracle.sol │
                 │  updateDiscountFactors│
                 └───────────────────────┘
```

## File Structure

```
sofr-rate-workflow/
├── main.ts                  # Workflow entry point
├── abi/
│   ├── YieldCurveOracle.ts  # Contract ABI for type-safe interactions
│   └── index.ts             # ABI exports
├── config.staging.json      # Staging environment config
├── config.production.json   # Production environment config
├── workflow.yaml            # CRE workflow settings
├── package.json             # Dependencies
├── tsconfig.json            # TypeScript config
└── README.md                # This file
```

## Key Concepts

### Discount Factor Formula

```
DF(t) = 1 / (1 + r)^t
```

Where:
- `r` = annual rate (derived from SOFR)
- `t` = time to maturity in years
- Result is scaled to WAD (1e18) precision

### Consensus

Each DON node independently fetches the SOFR rate. Results are aggregated using **median consensus** to produce a single trusted value, protecting against any single node returning incorrect data.

### Rate Estimation

For tenors beyond the available SOFR averages (30/90/180-day), the workflow uses interpolation and a simplified term premium model (~2bps/year) to estimate rates for longer tenors.

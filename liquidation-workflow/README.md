# Liquidation Workflow

A Chainlink CRE workflow for monitoring and initiating liquidation auctions for undercollateralized accounts in the ClearRate CCP.

## Overview

This workflow:
1. **Triggers on a cron schedule** - Runs hourly by default (configurable)
2. **Fetches liquidation targets** from the `/api/liquidation-monitoring/targets` API endpoint
3. **Executes liquidation transactions** by calling the `LiquidationEngine` contract with report type 0 if targets exist

## How It Works

### Liquidation Targets API

The workflow fetches accounts where `total_collateral < maintenance_margin` from the liquidation monitoring API:

```
GET /api/liquidation-monitoring/targets
```

Response:
```json
{
  "success": true,
  "liquidationTargets": [
    {
      "accountId": "0x1234...",
      "collateralToken": "0xabcd...",
      "totalCollateral": "1000000000000000000",
      "maintenanceMargin": "2000000000000000000"
    }
  ],
  "count": 1
}
```

### Onchain Execution

If liquidation targets exist, the workflow:
1. ABI-encodes the liquidation targets with report type 0
2. Generates a consensus-signed report via the CRE SDK
3. Submits the report to the `LiquidationEngine` contract

The `LiquidationEngine._processReport()` function handles report type 0 by:
- Starting Dutch auctions for each undercollateralized account
- Allowing liquidators to absorb positions at a decaying premium

## Configuration

### Config Schema

```typescript
{
  schedule: string,              // Cron schedule (e.g., "0 * * * *" = hourly)
  evms: [{
    liquidationEngineAddress: string,  // LiquidationEngine contract address
    chainSelectorName: string,         // Chain selector (e.g., "ethereum-testnet-sepolia")
    gasLimit: string,                  // Gas limit for transactions
  }],
  liquidationMonitoring: {
    apiEndpoint: string,         // URL to fetch liquidation targets
  }
}
```

### Environment Files

- `config.staging.json` - Staging/testnet configuration
- `config.production.json` - Production/mainnet configuration

## Usage

### Install Dependencies

```bash
cd liquidation-workflow
bun install
```

### Simulate Workflow

```bash
bun run start
```

Or using the CRE CLI directly:

```bash
cre workflow simulate . --target staging-settings --broadcast
```

## Contract Integration

The workflow interacts with the `LiquidationEngine` contract which inherits from `ReceiverTemplate`. The encoded report format:

```
abi.encode(uint8(0), LiquidationTarget[] targets)
```

Where `LiquidationTarget` struct:
```solidity
struct LiquidationTarget {
    bytes32 accountId;       // Account to liquidate
    address collateralToken; // Collateral token for the auction
}
```

## Related

- `settle-vm-workflow` - VM settlement workflow for cleared positions
- `LiquidationEngine.sol` - Contract handling Dutch auction liquidations
- `/api/liquidation-monitoring/targets` - API endpoint for fetching targets
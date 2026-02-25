# Settle VM Workflow

Chainlink CRE workflow for settling variation margin in the ClearRate CCP.

## Overview

This workflow enables automated daily variation margin (VM) settlement for cleared Interest Rate Swap positions. It calls the `ClearingHouse._processReport()` function with report type `1` (VM settlement).

## Report Format

The workflow encodes the report as:
```
abi.encode(uint8(1), VMSettlement[])
```

Where:
- `uint8(1)` = Report type indicating VM settlement
- `VMSettlement[]` = Array of (accountId, vmAmount) pairs

## Usage

### Install Dependencies

```bash
bun install
```

### Run the Workflow

```bash
bun start
```

Or using the CRE CLI directly:

```bash
cre workflow simulate . --target staging-settings --broadcast
```

## Input Payload Format

```json
{
  "settlements": [
    {
      "accountId": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      "vmAmount": "1000000"
    }
  ],
  "metadata": {
    "settlementDate": "2024-01-15",
    "npvSource": "LSEG Analytics API"
  }
}
```

- `accountId`: 32-byte hex string (bytes32)
- `vmAmount`: Signed integer string (positive = credit, negative = debit)

## Contract Integration

The workflow sends the encoded report to the `ClearingHouse` contract via the Chainlink Forwarder. The `_processReport()` function decodes the report type and routes to the appropriate handler:

- Report Type `0`: Trade submission (MatchedTrade)
- Report Type `1`: VM settlement (VMSettlement[])

## Configuration

See `config.staging.json` and `config.production.json` for chain and contract configuration.

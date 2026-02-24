# Create Trade Workflow

This workflow is responsible for submitting matched trades to the ClearRate ClearingHouse contract. It accepts trade data via HTTP trigger and executes an EVM transaction to call the `submitMatchedTrade` function.

## Overview

The workflow:
1. **Triggered by HTTP** - Accepts trade data via HTTP POST request
2. **Validates Payload** - Parses and validates the trade payload matching `trade.json` structure
3. **Executes EVM Transaction** - Calls `submitMatchedTrade` on the ClearingHouse contract with:
   - MatchedTrade struct (trade details)
   - Signature from party A (sigA)
   - Signature from party B (sigB)

## Payload Structure

The HTTP request body should contain a JSON payload matching the structure in `contracts/scripts-js/trade.json`:

```json
{
  "trade": {
    "tradeId": "0x...",
    "partyA": "0x...",
    "partyB": "0x...",
    "notional": "1000000000000000000000000",
    "fixedRateBps": 350,
    "startDate": 1772016961,
    "maturityDate": 1803552961,
    "paymentInterval": 7776000,
    "dayCountConvention": 0,
    "floatingRateIndex": "0x...",
    "nonce": 1,
    "deadline": 1772103361
  },
  "sigA": "0x...",
  "sigB": "0x..."
}
```

## Configuration

### Staging (`config.staging.json`)
```json
{
  "evms": [
    {
      "clearingHouseAddress": "0x...",
      "chainSelectorName": "ethereum-testnet-sepolia",
      "gasLimit": "500000"
    }
  ]
}
```

### Production (`config.production.json`)
```json
{
  "evms": [
    {
      "clearingHouseAddress": "0x...",
      "chainSelectorName": "ethereum-mainnet",
      "gasLimit": "500000"
    }
  ]
}
```

## Contract Interaction

The workflow calls `ClearingHouse.submitMatchedTrade()` with the following signature:

```solidity
function submitMatchedTrade(
    MatchedTrade calldata trade,
    bytes calldata sigA,
    bytes calldata sigB
) external nonReentrant onlyRole(OPERATOR_ROLE)
```

Where `MatchedTrade` is:
```solidity
struct MatchedTrade {
    bytes32 tradeId;
    bytes32 partyA;
    bytes32 partyB;
    uint256 notional;
    uint256 fixedRateBps;
    uint256 startDate;
    uint256 maturityDate;
    uint256 paymentInterval;
    uint8 dayCountConvention;
    bytes32 floatingRateIndex;
    uint256 nonce;
    uint256 deadline;
}
```

## Usage

```bash
# Install dependencies
bun install

# Run the workflow
bun run main.ts
```

## Dependencies

- `@chainlink/cre-sdk` - Chainlink CRE SDK for workflow execution
- `viem` - Ethereum ABI encoding
- `zod` - Schema validation

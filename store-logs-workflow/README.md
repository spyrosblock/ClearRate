# Store Logs Workflow

This workflow is responsible for storing novated trade events and position matured events from the ClearRate ClearingHouse contract to a PostgreSQL database.

## Overview

The workflow:
1. **Triggered by EVM Logs** - Listens for TradeNovated and PositionMatured events from the ClearingHouse contract
2. **Reads Position Data** - Fetches full position details from the blockchain using the `getPosition` function
3. **Stores to Database** - Sends the novated position data to the database API endpoint via HTTP POST with DON consensus

## Events Handled

### TradeNovated
Emitted when a trade is novated on the ClearingHouse contract. This event triggers the creation of a new novated position record in the database.

Event signature:
```solidity
event TradeNovated(bytes32 indexed tradeId, uint256 tokenIdA, uint256 tokenIdB)
```

### PositionMatured
Emitted when a position reaches its maturity date. This event triggers an update to set the position's `active` field to `false`.

Event signature:
```solidity
event PositionMatured(bytes32 indexed tradeId, uint256 timestamp)
```

## Database Schema

The workflow stores data to the `novated_positions` table defined in `db/init/01-init.sql`:

| Column | Type | Description |
|--------|------|-------------|
| trade_id | VARCHAR(66) | bytes32 as hex string (UNIQUE) |
| token_id_a | VARCHAR(78) | uint256 as string (ERC-1155 token ID for party A) |
| token_id_b | VARCHAR(78) | uint256 as string (ERC-1155 token ID for party B) |
| party_a | VARCHAR(66) | bytes32 account ID (pays fixed) |
| party_b | VARCHAR(66) | bytes32 account ID (receives fixed) |
| notional | NUMERIC(78,0) | Current notional amount |
| fixed_rate_bps | INTEGER | Fixed rate in basis points |
| start_date | TIMESTAMPTZ | Swap effective date |
| maturity_date | TIMESTAMPTZ | Swap maturity date |
| active | BOOLEAN | Position active status |
| last_npv | NUMERIC(78,0) | Last mark-to-market NPV |

## Configuration

### Staging (`config.staging.json`)
```json
{
  "evms": [
    {
      "clearingHouseAddress": "0xbA4f1825CA34AE68035Fbb615273e6406e7F3271",
      "chainSelectorName": "ethereum-testnet-sepolia",
      "gasLimit": "2000000"
    }
  ],
  "dbApi": {
    "url": "http://host.docker.internal:3000/api/novated-positions"
  }
}
```

### Production (`config.production.json`)
```json
{
  "evms": [
    {
      "clearingHouseAddress": "0xbA4f1825CA34AE68035Fbb615273e6406e7F3271",
      "chainSelectorName": "ethereum-mainnet",
      "gasLimit": "2000000"
    }
  ],
  "dbApi": {
    "url": "https://api.clearrate.com/api/novated-positions"
  }
}
```

## API Payload Structure

### TradeNovated Action
```json
{
  "action": "TradeNovated",
  "tradeId": "0x...",
  "tokenIdA": "123...",
  "tokenIdB": "456...",
  "partyA": "0x...",
  "partyB": "0x...",
  "notional": "1000000000000000000",
  "fixedRateBps": "350",
  "startDate": "1772016961",
  "maturityDate": "1803552961",
  "active": true,
  "lastNpv": "0"
}
```

### PositionMatured Action
```json
{
  "action": "PositionMatured",
  "tradeId": "0x..."
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
- `viem` - Ethereum ABI encoding/decoding
- `zod` - Schema validation

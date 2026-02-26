-- 01-init.sql
-- Stores novated positions from ClearRate ClearingHouse

-- Novated positions table - mirrors NovatedPosition struct from IClearingHouse
CREATE TABLE novated_positions (
    id              SERIAL PRIMARY KEY,
    trade_id        VARCHAR(66) UNIQUE NOT NULL,          -- bytes32 as hex string with '0x' prefix
    token_id_a      VARCHAR(78) NOT NULL,                  -- uint256 as string (ERC-1155 token ID for party A)
    token_id_b      VARCHAR(78) NOT NULL,                  -- uint256 as string (ERC-1155 token ID for party B)
    party_a         VARCHAR(66) NOT NULL,                  -- bytes32 account ID (pays fixed)
    party_b         VARCHAR(66) NOT NULL,                  -- bytes32 account ID (receives fixed)
    notional        NUMERIC(78, 0) NOT NULL,               -- Current notional amount (may be reduced after compression)
    original_notional NUMERIC(78, 0) NOT NULL,             -- Original notional at novation
    fixed_rate_bps  INTEGER NOT NULL,                       -- Fixed rate in basis points
    start_date      TIMESTAMPTZ NOT NULL,                  -- Swap effective date
    maturity_date   TIMESTAMPTZ NOT NULL,                  -- Swap maturity date
    active          BOOLEAN DEFAULT TRUE,                  -- Position active status
    last_npv        NUMERIC(78, 0) DEFAULT 0,              -- Last mark-to-market NPV (int256)
    created_at      TIMESTAMPTZ DEFAULT NOW(),            -- Record creation timestamp
    updated_at      TIMESTAMPTZ DEFAULT NOW()             -- Last update timestamp
);

-- Index for fast lookups by party
CREATE INDEX idx_novated_positions_party_a ON novated_positions(party_a);
CREATE INDEX idx_novated_positions_party_b ON novated_positions(party_b);

-- Index for active positions only
CREATE INDEX idx_novated_positions_active ON novated_positions(active) WHERE active = TRUE;

-- Index for maturity date queries
CREATE INDEX idx_novated_positions_maturity ON novated_positions(maturity_date);

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
    notional        NUMERIC(78, 0) NOT NULL,               -- Notional amount
    fixed_rate_bps  INTEGER NOT NULL,                       -- Fixed rate in basis points
    start_date      TIMESTAMPTZ NOT NULL,                  -- Swap effective date
    maturity_date   TIMESTAMPTZ NOT NULL,                  -- Swap maturity date
    active          BOOLEAN DEFAULT TRUE,                  -- Position active status
    last_npv        NUMERIC(78, 0) DEFAULT 0,              -- Last mark-to-market NPV (int256)
    collateral_token VARCHAR(42) NOT NULL,                  -- Single collateral token address for IM and VM
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

-- Users table - stores user KYB information and company details
CREATE TABLE users (
    id                          SERIAL PRIMARY KEY,
    address                     VARCHAR(42) UNIQUE NOT NULL,          -- Ethereum address (0x + 40 hex chars)
    account_id                  VARCHAR(66),                          -- bytes32 account ID (optional, set after approval)
    company_name                VARCHAR(255) NOT NULL,
    registration_number         VARCHAR(100) UNIQUE NOT NULL,
    registered_country          VARCHAR(2) NOT NULL,                  -- ISO 3166-1 alpha-2 country code
    contact_email               VARCHAR(255) NOT NULL,
    lei                         VARCHAR(20) UNIQUE NOT NULL,          -- Legal Entity Identifier (20 alphanumeric chars)
    website                     VARCHAR(500) NOT NULL,
    articles_of_association     VARCHAR(1000),                        -- URL to articles of association
    certificate_of_incorporation VARCHAR(1000),                       -- URL to certificate of incorporation
    vat_certificate             VARCHAR(1000),                        -- URL to VAT certificate
    iban                        VARCHAR(34) NOT NULL,                 -- IBAN (max 34 chars)
    bic                         VARCHAR(11) NOT NULL,                 -- BIC/SWIFT (8 or 11 chars)
    approved                    BOOLEAN DEFAULT FALSE,                -- KYB approval status
    valid_until                 TIMESTAMPTZ,                          -- Approval validity date
    max_notional                NUMERIC(78, 0) DEFAULT 0,             -- Maximum notional allowed
    notional                    NUMERIC(78, 0) DEFAULT 0,             -- Current notional used
    created_at                  TIMESTAMPTZ DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ DEFAULT NOW()
);

-- Index for user lookups by address
CREATE INDEX idx_users_address ON users(address);

-- Index for user lookups by account_id
CREATE INDEX idx_users_account_id ON users(account_id);

-- Index for approved users
CREATE INDEX idx_users_approved ON users(approved) WHERE approved = TRUE;

-- Liquidation monitoring table - tracks account collateral and margin status
CREATE TABLE liquidation_monitoring (
    id                  SERIAL PRIMARY KEY,
    account_id          VARCHAR(66) NOT NULL,                  -- bytes32 account ID
    total_collateral    NUMERIC(78, 0) NOT NULL,               -- Total collateral amount (uint256)
    maintenance_margin  NUMERIC(78, 0) NOT NULL,               -- Maintenance margin requirement (uint256)
    collateral_token    VARCHAR(42) NOT NULL,                  -- Collateral token address
    created_at          TIMESTAMPTZ DEFAULT NOW(),            -- Record creation timestamp
    updated_at          TIMESTAMPTZ DEFAULT NOW()             -- Last update timestamp
);

-- Index for fast lookups by account_id
CREATE INDEX idx_liquidation_monitoring_account_id ON liquidation_monitoring(account_id);

-- Index for fast lookups by account_id + collateral_token combination
CREATE INDEX idx_liquidation_monitoring_account_token ON liquidation_monitoring(account_id, collateral_token);

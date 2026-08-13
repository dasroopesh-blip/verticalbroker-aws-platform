-- =============================================================================
-- VerticalBroker Local PostgreSQL Initialization
-- Simulates Aurora PostgreSQL schema for local development.
-- Source of truth: orders, wallets, trades (ACID)
-- =============================================================================

-- Create schema
CREATE SCHEMA IF NOT EXISTS trading;
SET search_path TO trading, public;

-- Orders table (ledger truth)
CREATE TABLE IF NOT EXISTS trading.orders (
    order_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id VARCHAR(50) NOT NULL,
    account_id VARCHAR(50) NOT NULL,
    instrument_id VARCHAR(20) NOT NULL,
    side VARCHAR(4) NOT NULL CHECK (side IN ('BUY', 'SELL')),
    order_type VARCHAR(10) NOT NULL CHECK (order_type IN ('LIMIT', 'MARKET', 'STOP', 'STOP_LIMIT')),
    quantity NUMERIC(18, 8) NOT NULL CHECK (quantity > 0),
    price NUMERIC(18, 8),
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'ACCEPTED', 'FILLED', 'PARTIALLY_FILLED', 'CANCELLED', 'REJECTED')),
    time_in_force VARCHAR(3) NOT NULL DEFAULT 'GTC' CHECK (time_in_force IN ('GTC', 'IOC', 'FOK', 'DAY')),
    filled_quantity NUMERIC(18, 8) DEFAULT 0,
    avg_fill_price NUMERIC(18, 8),
    idempotency_key VARCHAR(100) UNIQUE,
    correlation_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    filled_at TIMESTAMPTZ
);

-- Wallets / Portfolio positions
CREATE TABLE IF NOT EXISTS trading.portfolios (
    client_id VARCHAR(50) NOT NULL,
    account_id VARCHAR(50) NOT NULL,
    instrument_id VARCHAR(20) NOT NULL,
    quantity NUMERIC(18, 8) NOT NULL DEFAULT 0,
    avg_cost_basis NUMERIC(18, 8) NOT NULL DEFAULT 0,
    realized_pnl NUMERIC(18, 8) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (client_id, account_id, instrument_id)
);

-- Trade executions (audit trail)
CREATE TABLE IF NOT EXISTS trading.executions (
    execution_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES trading.orders(order_id),
    client_id VARCHAR(50) NOT NULL,
    account_id VARCHAR(50) NOT NULL,
    instrument_id VARCHAR(20) NOT NULL,
    side VARCHAR(4) NOT NULL,
    quantity NUMERIC(18, 8) NOT NULL,
    price NUMERIC(18, 8) NOT NULL,
    fee NUMERIC(18, 8) DEFAULT 0,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    venue VARCHAR(20) DEFAULT 'NYSE'
);

-- Client accounts
CREATE TABLE IF NOT EXISTS trading.accounts (
    account_id VARCHAR(50) PRIMARY KEY,
    client_id VARCHAR(50) NOT NULL,
    account_type VARCHAR(20) NOT NULL DEFAULT 'BROKERAGE',
    status VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    margin_enabled BOOLEAN DEFAULT FALSE,
    cash_balance NUMERIC(18, 8) NOT NULL DEFAULT 0,
    buying_power NUMERIC(18, 8) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_orders_client ON trading.orders(client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_instrument ON trading.orders(instrument_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_status ON trading.orders(status) WHERE status IN ('PENDING', 'ACCEPTED');
CREATE INDEX IF NOT EXISTS idx_portfolios_client ON trading.portfolios(client_id);
CREATE INDEX IF NOT EXISTS idx_executions_order ON trading.executions(order_id);
CREATE INDEX IF NOT EXISTS idx_executions_client ON trading.executions(client_id, executed_at DESC);

-- Enable logical replication for CDC (DMS)
ALTER SYSTEM SET wal_level = 'logical';

-- Seed test data
INSERT INTO trading.accounts (account_id, client_id, account_type, status, margin_enabled, cash_balance, buying_power)
VALUES
    ('account-001', 'client-001', 'BROKERAGE', 'ACTIVE', true, 100000.00, 200000.00),
    ('account-002', 'client-002', 'BROKERAGE', 'ACTIVE', false, 50000.00, 50000.00),
    ('account-003', 'client-003', 'IRA', 'ACTIVE', false, 250000.00, 250000.00);

-- Grant permissions
GRANT ALL ON SCHEMA trading TO vb_admin;
GRANT ALL ON ALL TABLES IN SCHEMA trading TO vb_admin;

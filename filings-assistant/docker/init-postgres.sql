-- Local Postgres bootstrap for filings-assistant.
-- The application also creates this schema on startup (idempotent), but having
-- it here means the table exists immediately when the container is first run.

CREATE TABLE IF NOT EXISTS filings (
    filing_id        TEXT PRIMARY KEY,
    cik              TEXT NOT NULL,
    ticker           TEXT,
    company_name     TEXT NOT NULL,
    form             TEXT NOT NULL,
    accession_number TEXT NOT NULL,
    filing_date      DATE NOT NULL,
    source_url       TEXT NOT NULL,
    content_sha256   TEXT NOT NULL UNIQUE,
    raw_text         TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'PENDING',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_filings_cik ON filings (cik);
CREATE INDEX IF NOT EXISTS idx_filings_status ON filings (status);

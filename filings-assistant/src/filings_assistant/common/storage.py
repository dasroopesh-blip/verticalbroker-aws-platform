"""Persistence layer: Postgres source-of-truth repository and a queue.

Postgres is the authoritative store for raw filings + ingest status. OpenSearch
is a derived index that can always be rebuilt from here. The queue decouples
slow ingestion (fetch/chunk/embed/index) from the fast API path.

Both come in two flavors:
    - Real:  psycopg (Postgres) and boto3 SQS.
    - Local: an in-memory repo + queue for offline dev/tests.

The factory functions pick an implementation based on Settings.run_mode.
"""

from __future__ import annotations

import json
from collections import deque
from datetime import date, datetime
from typing import Protocol

from filings_assistant.common.config import RunMode, Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.models import Filing, IngestJob, IngestStatus

logger = get_logger("common.storage")


# ---------------------------------------------------------------------------
# Repository interface
# ---------------------------------------------------------------------------
class FilingRepository(Protocol):
    """Stores filings and tracks their ingest status.

    Every method is tenant-scoped: reads/writes are constrained to ``tenant_id``
    so one tenant can never see or mutate another's filings.
    """

    def upsert_filing(self, filing: Filing) -> bool:
        """Insert a filing; return False if an identical checksum already exists
        FOR THIS TENANT."""
        ...

    def get_filing(self, tenant_id: str, filing_id: str) -> Filing | None: ...

    def set_status(self, tenant_id: str, filing_id: str, status: IngestStatus) -> None: ...

    def list_filings(self, tenant_id: str, limit: int = 50) -> list[Filing]: ...


class JobQueue(Protocol):
    """A minimal enqueue/dequeue interface (SQS or local)."""

    def enqueue(self, job: IngestJob) -> None: ...

    def dequeue(self, max_messages: int = 1) -> list[IngestJob]: ...


# ---------------------------------------------------------------------------
# In-memory implementations (local dev / tests)
# ---------------------------------------------------------------------------
class InMemoryRepository:
    """Process-local filing store keyed by filing_id, with per-tenant checksum
    dedup and tenant-scoped reads."""

    def __init__(self) -> None:
        self._by_id: dict[str, Filing] = {}
        # Dedup checksums scoped per tenant: (tenant_id, sha256).
        self._checksums: set[tuple[str, str]] = set()

    def upsert_filing(self, filing: Filing) -> bool:
        key = (filing.tenant_id, filing.content_sha256)
        if key in self._checksums:
            logger.info("Skipping duplicate filing (checksum match)", tenant_id=filing.tenant_id, cik=filing.cik)
            return False
        self._by_id[filing.filing_id] = filing
        self._checksums.add(key)
        return True

    def get_filing(self, tenant_id: str, filing_id: str) -> Filing | None:
        filing = self._by_id.get(filing_id)
        # Tenant guard: never return another tenant's filing.
        if filing is None or filing.tenant_id != tenant_id:
            return None
        return filing

    def set_status(self, tenant_id: str, filing_id: str, status: IngestStatus) -> None:
        filing = self._by_id.get(filing_id)
        if filing is not None and filing.tenant_id == tenant_id:
            filing.status = status

    def list_filings(self, tenant_id: str, limit: int = 50) -> list[Filing]:
        return [f for f in self._by_id.values() if f.tenant_id == tenant_id][:limit]


class InMemoryQueue:
    """Process-local FIFO queue standing in for SQS."""

    def __init__(self) -> None:
        self._q: deque[IngestJob] = deque()

    def enqueue(self, job: IngestJob) -> None:
        self._q.append(job)

    def dequeue(self, max_messages: int = 1) -> list[IngestJob]:
        out: list[IngestJob] = []
        while self._q and len(out) < max_messages:
            out.append(self._q.popleft())
        return out


# ---------------------------------------------------------------------------
# Postgres implementation
# ---------------------------------------------------------------------------
# Note: the checksum uniqueness is scoped PER TENANT — the same public filing
# can be independently ingested by different tenants without collision.
_SCHEMA = """
CREATE TABLE IF NOT EXISTS filings (
    filing_id        TEXT PRIMARY KEY,
    tenant_id        TEXT NOT NULL,
    cik              TEXT NOT NULL,
    ticker           TEXT,
    company_name     TEXT NOT NULL,
    form             TEXT NOT NULL,
    accession_number TEXT NOT NULL,
    filing_date      DATE NOT NULL,
    source_url       TEXT NOT NULL,
    content_sha256   TEXT NOT NULL,
    raw_text         TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'PENDING',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, content_sha256)
);
CREATE INDEX IF NOT EXISTS idx_filings_tenant ON filings (tenant_id);
CREATE INDEX IF NOT EXISTS idx_filings_tenant_status ON filings (tenant_id, status);

-- Defense in depth: Row-Level Security so a session can only see its tenant's
-- rows. The application sets `SET app.tenant_id = '<tenant>'` per connection.
ALTER TABLE filings ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'filings' AND policyname = 'tenant_isolation') THEN
        CREATE POLICY tenant_isolation ON filings
            USING (tenant_id = current_setting('app.tenant_id', true));
    END IF;
END$$;
"""


class PostgresRepository:
    """Aurora/RDS Postgres-backed source of truth."""

    def __init__(self, settings: Settings) -> None:
        import psycopg  # lazy import so local mode needs no driver

        self._psycopg = psycopg
        self._dsn = settings.pg_dsn
        self._ensure_schema()

    def _connect(self):
        return self._psycopg.connect(self._dsn)

    def _ensure_schema(self) -> None:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(_SCHEMA)
            conn.commit()

    def _set_tenant(self, cur, tenant_id: str) -> None:
        """Set the RLS session variable so Row-Level Security scopes all queries."""
        cur.execute("SELECT set_config('app.tenant_id', %s, true)", (tenant_id,))

    def upsert_filing(self, filing: Filing) -> bool:
        with self._connect() as conn, conn.cursor() as cur:
            self._set_tenant(cur, filing.tenant_id)
            cur.execute(
                """
                INSERT INTO filings (filing_id, tenant_id, cik, ticker, company_name, form,
                    accession_number, filing_date, source_url, content_sha256,
                    raw_text, status)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (tenant_id, content_sha256) DO NOTHING
                """,
                (
                    filing.filing_id, filing.tenant_id, filing.cik, filing.ticker, filing.company_name,
                    filing.form.value, filing.accession_number, filing.filing_date,
                    filing.source_url, filing.content_sha256, filing.raw_text,
                    filing.status.value,
                ),
            )
            inserted = cur.rowcount == 1
            conn.commit()
            return inserted

    def get_filing(self, tenant_id: str, filing_id: str) -> Filing | None:
        with self._connect() as conn, conn.cursor() as cur:
            self._set_tenant(cur, tenant_id)
            # Explicit tenant predicate in addition to RLS (belt and suspenders).
            cur.execute("SELECT * FROM filings WHERE filing_id = %s AND tenant_id = %s", (filing_id, tenant_id))
            row = cur.fetchone()
            if not row:
                return None
            cols = [d.name for d in cur.description]
            return _row_to_filing(dict(zip(cols, row, strict=True)))

    def set_status(self, tenant_id: str, filing_id: str, status: IngestStatus) -> None:
        with self._connect() as conn, conn.cursor() as cur:
            self._set_tenant(cur, tenant_id)
            cur.execute(
                "UPDATE filings SET status=%s, updated_at=now() WHERE filing_id=%s AND tenant_id=%s",
                (status.value, filing_id, tenant_id),
            )
            conn.commit()

    def list_filings(self, tenant_id: str, limit: int = 50) -> list[Filing]:
        with self._connect() as conn, conn.cursor() as cur:
            self._set_tenant(cur, tenant_id)
            cur.execute(
                "SELECT * FROM filings WHERE tenant_id = %s ORDER BY created_at DESC LIMIT %s",
                (tenant_id, limit),
            )
            cols = [d.name for d in cur.description]
            return [_row_to_filing(dict(zip(cols, r, strict=True))) for r in cur.fetchall()]


def _row_to_filing(row: dict) -> Filing:
    """Rebuild a Filing from a DB row dict."""
    if isinstance(row.get("filing_date"), str):
        row["filing_date"] = date.fromisoformat(row["filing_date"])
    return Filing.model_validate(row)


class SqsQueue:
    """Amazon SQS-backed job queue."""

    def __init__(self, settings: Settings) -> None:
        import boto3

        self._sqs = boto3.client("sqs", region_name=settings.aws_region)
        self._url = settings.queue_url

    def enqueue(self, job: IngestJob) -> None:
        self._sqs.send_message(QueueUrl=self._url, MessageBody=job.model_dump_json())

    def dequeue(self, max_messages: int = 1) -> list[IngestJob]:
        resp = self._sqs.receive_message(QueueUrl=self._url, MaxNumberOfMessages=max_messages)
        jobs: list[IngestJob] = []
        for msg in resp.get("Messages", []):
            jobs.append(IngestJob.model_validate(json.loads(msg["Body"])))
            self._sqs.delete_message(QueueUrl=self._url, ReceiptHandle=msg["ReceiptHandle"])
        return jobs


# ---------------------------------------------------------------------------
# Factories + module-level singletons for local mode
# ---------------------------------------------------------------------------
_LOCAL_REPO = InMemoryRepository()
_LOCAL_QUEUE = InMemoryQueue()


def get_repository(settings: Settings | None = None) -> FilingRepository:
    """Return a Postgres or in-memory repository based on run mode."""
    settings = settings or get_settings()
    if settings.run_mode == RunMode.AWS:
        try:
            return PostgresRepository(settings)
        except Exception as exc:  # pragma: no cover - env dependent
            logger.warning("Postgres unavailable, using in-memory repo", error=str(exc))
    return _LOCAL_REPO


def get_queue(settings: Settings | None = None) -> JobQueue:
    """Return an SQS or in-memory queue based on run mode."""
    settings = settings or get_settings()
    if settings.run_mode == RunMode.AWS and settings.queue_url:
        try:
            return SqsQueue(settings)
        except Exception as exc:  # pragma: no cover - env dependent
            logger.warning("SQS unavailable, using in-memory queue", error=str(exc))
    return _LOCAL_QUEUE


__all__ = [
    "FilingRepository", "JobQueue", "get_repository", "get_queue",
    "InMemoryRepository", "InMemoryQueue", "PostgresRepository", "SqsQueue",
]

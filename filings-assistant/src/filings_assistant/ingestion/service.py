"""Ingestion service: fetch -> store in Postgres (truth) -> enqueue.

This is the write path. It deliberately does NOT embed or index; that slow work
is handed to the worker via the queue, keeping ingestion fast and decoupled.
Idempotency comes from the content checksum unique constraint in the repo.
"""

from __future__ import annotations

from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.common.storage import FilingRepository, JobQueue, get_queue, get_repository
from filings_assistant.common.tenant import TenantContext
from filings_assistant.ingestion.sec_client import SecEdgarClient
from filings_assistant.models import Filing, FilingForm, IngestJob, IngestStatus

logger = get_logger("ingestion.service")


class IngestionService:
    """Coordinates SEC fetch, persistence, and enqueue."""

    def __init__(
        self,
        settings: Settings | None = None,
        sec_client: SecEdgarClient | None = None,
        repo: FilingRepository | None = None,
        queue: JobQueue | None = None,
    ) -> None:
        self._settings = settings or get_settings()
        self._sec = sec_client or SecEdgarClient(self._settings)
        self._repo = repo or get_repository(self._settings)
        self._queue = queue or get_queue(self._settings)

    def ingest(self, tenant: TenantContext, ticker: str, form: FilingForm, limit: int = 1) -> list[Filing]:
        """Fetch filings for a ticker/form and enqueue new ones for indexing.

        All stored filings and enqueued jobs are tagged with ``tenant.tenant_id``,
        so a filing ingested by one tenant is invisible to every other tenant.
        """
        raw_filings = self._sec.fetch_filings(ticker, form, limit)
        stored: list[Filing] = []
        for raw in raw_filings:
            filing = Filing(
                tenant_id=tenant.tenant_id,
                cik=raw.cik, ticker=raw.ticker, company_name=raw.company_name,
                form=raw.form, accession_number=raw.accession_number,
                filing_date=raw.filing_date, source_url=raw.source_url,
                content_sha256=raw.content_sha256, raw_text=raw.text,
                status=IngestStatus.PENDING,
            )
            is_new = self._repo.upsert_filing(filing)
            if not is_new:
                logger.info(
                    "Filing already ingested; skipping",
                    ticker=ticker, accession=raw.accession_number, **tenant.log_fields(),
                )
                continue
            self._queue.enqueue(IngestJob(tenant_id=tenant.tenant_id, filing_id=filing.filing_id, cik=filing.cik))
            stored.append(filing)
            logger.info(
                "Ingested filing",
                ticker=ticker, form=form.value,
                accession=raw.accession_number, filing_id=filing.filing_id, **tenant.log_fields(),
            )
        return stored

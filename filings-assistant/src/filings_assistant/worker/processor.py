"""Indexing worker: queue -> chunk -> embed (Bedrock) -> OpenSearch.

This is the slow, async half of ingestion, decoupled from the write path via
the queue. For each queued filing it:
    1. loads the raw text from Postgres (source of truth),
    2. chunks it with overlap,
    3. embeds each chunk via Bedrock Titan,
    4. bulk-indexes the chunks into OpenSearch,
    5. updates the filing status (INDEXING -> INDEXED / FAILED).

In AWS this runs as a Lambda triggered by SQS; ``drain()`` is the local-dev
equivalent that processes everything currently queued.
"""

from __future__ import annotations

from filings_assistant.common.bedrock import BedrockClient, get_bedrock_client
from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.common.storage import FilingRepository, JobQueue, get_queue, get_repository
from filings_assistant.common.tenant import TenantContext
from filings_assistant.models import Chunk, Filing, IngestJob, IngestStatus
from filings_assistant.search.chunker import chunk_text
from filings_assistant.search.opensearch_store import VectorStore, get_vector_store

logger = get_logger("worker.processor")


class WorkerProcessor:
    """Consumes ingest jobs and makes filings searchable."""

    def __init__(
        self,
        settings: Settings | None = None,
        repo: FilingRepository | None = None,
        queue: JobQueue | None = None,
        store: VectorStore | None = None,
        bedrock: BedrockClient | None = None,
    ) -> None:
        self._settings = settings or get_settings()
        self._repo = repo or get_repository(self._settings)
        self._queue = queue or get_queue(self._settings)
        self._store = store or get_vector_store(self._settings)
        self._bedrock = bedrock or get_bedrock_client(self._settings)

    def process_job(self, job: IngestJob) -> bool:
        """Process one job. Returns True on success. Fully tenant-scoped."""
        tenant = TenantContext.from_auth(job.tenant_id)
        filing = self._repo.get_filing(tenant.tenant_id, job.filing_id)
        if filing is None:
            logger.error("Filing not found for job", filing_id=job.filing_id, **tenant.log_fields())
            return False
        try:
            self._repo.set_status(tenant.tenant_id, filing.filing_id, IngestStatus.INDEXING)
            self._store.ensure_index(tenant)
            chunks = self._build_chunks(filing)
            self._embed_chunks(chunks)
            indexed = self._store.index_chunks(tenant, chunks)
            self._repo.set_status(tenant.tenant_id, filing.filing_id, IngestStatus.INDEXED)
            logger.info("Indexed filing", filing_id=filing.filing_id, chunks=indexed, **tenant.log_fields())
            return True
        except Exception as exc:
            logger.error("Failed to index filing", filing_id=filing.filing_id, error=str(exc), **tenant.log_fields())
            self._repo.set_status(tenant.tenant_id, filing.filing_id, IngestStatus.FAILED)
            return False

    def _build_chunks(self, filing: Filing) -> list[Chunk]:
        pieces = chunk_text(
            filing.raw_text,
            chunk_size_tokens=self._settings.chunk_size_tokens,
            overlap_tokens=self._settings.chunk_overlap_tokens,
        )
        return [
            Chunk(
                tenant_id=filing.tenant_id, filing_id=filing.filing_id, cik=filing.cik, ticker=filing.ticker,
                company_name=filing.company_name, form=filing.form,
                filing_date=filing.filing_date, source_url=filing.source_url,
                section=section, chunk_index=i, text=text,
            )
            for i, (text, section) in enumerate(pieces)
        ]

    def _embed_chunks(self, chunks: list[Chunk]) -> None:
        if not chunks:
            return
        embeddings = self._bedrock.embed_texts([c.text for c in chunks])
        for chunk, vector in zip(chunks, embeddings, strict=True):
            chunk.embedding = vector

    def drain(self, max_batches: int = 100) -> int:
        """Process all currently-queued jobs (local dev helper)."""
        processed = 0
        for _ in range(max_batches):
            jobs = self._queue.dequeue(max_messages=10)
            if not jobs:
                break
            for job in jobs:
                if self.process_job(job):
                    processed += 1
        return processed


def lambda_handler(event: dict, _context: object) -> dict:
    """AWS Lambda entrypoint for SQS-triggered indexing."""
    processor = WorkerProcessor()
    from filings_assistant.models import IngestJob as _Job

    ok = 0
    for record in event.get("Records", []):
        import json

        job = _Job.model_validate(json.loads(record["body"]))
        if processor.process_job(job):
            ok += 1
    return {"processed": ok, "total": len(event.get("Records", []))}

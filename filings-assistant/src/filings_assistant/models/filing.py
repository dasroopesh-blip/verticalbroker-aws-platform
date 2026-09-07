"""Domain models for filings, chunks, and search results.

These are the shared contracts used across ingestion, worker, search, and the
agent. Pydantic v2 models give validation + easy (de)serialization to/from
Postgres, SQS messages, and OpenSearch documents.
"""

from __future__ import annotations

from datetime import date, datetime, timezone
from enum import Enum
from uuid import uuid4

from pydantic import BaseModel, Field


def _utcnow() -> datetime:
    """Timezone-aware UTC now (project convention: never naive datetimes)."""
    return datetime.now(timezone.utc)


class FilingForm(str, Enum):
    """Supported SEC filing form types."""

    FORM_10K = "10-K"  # annual report
    FORM_10Q = "10-Q"  # quarterly report
    FORM_8K = "8-K"  # material events


class IngestStatus(str, Enum):
    """Lifecycle of a filing through the pipeline (tracked in Postgres)."""

    PENDING = "PENDING"  # stored, queued for embedding
    INDEXING = "INDEXING"  # worker is chunking/embedding
    INDEXED = "INDEXED"  # searchable in OpenSearch
    FAILED = "FAILED"  # gave up after retries


class Filing(BaseModel):
    """A single SEC filing (the source-of-truth record in Postgres)."""

    filing_id: str = Field(default_factory=lambda: str(uuid4()))
    tenant_id: str  # owning tenant; enforced at every layer for isolation
    cik: str  # SEC Central Index Key (zero-padded, 10 digits)
    ticker: str | None = None
    company_name: str
    form: FilingForm
    accession_number: str  # SEC unique filing id, e.g. 0000320193-23-000106
    filing_date: date
    source_url: str
    content_sha256: str  # checksum of raw text for idempotent re-ingest
    raw_text: str = ""  # full extracted text (stored in Postgres)
    status: IngestStatus = IngestStatus.PENDING
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)


class Chunk(BaseModel):
    """A chunk of filing text with its embedding (an OpenSearch document)."""

    chunk_id: str = Field(default_factory=lambda: str(uuid4()))
    tenant_id: str  # owning tenant; also indexed for defense-in-depth filtering
    filing_id: str
    cik: str
    ticker: str | None = None
    company_name: str
    form: FilingForm
    filing_date: date
    source_url: str
    section: str | None = None  # e.g. "Item 1A. Risk Factors" if detectable
    chunk_index: int  # position within the filing
    text: str
    embedding: list[float] | None = None  # populated by the worker

    def to_opensearch_doc(self) -> dict:
        """Serialize to the OpenSearch index document shape."""
        return {
            "chunk_id": self.chunk_id,
            "tenant_id": self.tenant_id,
            "filing_id": self.filing_id,
            "cik": self.cik,
            "ticker": self.ticker,
            "company_name": self.company_name,
            "form": self.form.value,
            "filing_date": self.filing_date.isoformat(),
            "source_url": self.source_url,
            "section": self.section,
            "chunk_index": self.chunk_index,
            "text": self.text,
            "embedding": self.embedding,
        }


class SearchHit(BaseModel):
    """A single retrieval result with provenance for citations."""

    chunk_id: str
    tenant_id: str = ""
    filing_id: str
    ticker: str | None
    company_name: str
    form: str
    filing_date: str
    section: str | None
    source_url: str
    text: str
    score: float

    def citation(self) -> str:
        """Human-readable citation, e.g. 'AAPL 10-K (2023-11-03), Item 1A'."""
        label = self.ticker or self.company_name
        base = f"{label} {self.form} ({self.filing_date})"
        return f"{base}, {self.section}" if self.section else base


class IngestJob(BaseModel):
    """Message placed on the queue after a filing is stored."""

    tenant_id: str
    filing_id: str
    cik: str
    enqueued_at: datetime = Field(default_factory=_utcnow)

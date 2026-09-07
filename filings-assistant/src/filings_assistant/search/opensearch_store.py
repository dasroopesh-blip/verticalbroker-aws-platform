"""OpenSearch vector + text store.

Defines the hybrid index mapping (a ``knn_vector`` field for semantic search
plus analyzed text for BM25 keyword search) and the read/write operations used
by the worker (index) and the search service (query).

A local in-memory implementation mirrors the same interface using brute-force
cosine similarity + naive term overlap, so retrieval works offline and in unit
tests without a running OpenSearch cluster.
"""

from __future__ import annotations

import math
from typing import Any, Protocol

from filings_assistant.common.config import RunMode, Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.common.tenant import TenantContext
from filings_assistant.models import Chunk, SearchHit

logger = get_logger("search.opensearch")

# Optional metadata filters applied at query time (e.g. {"ticker": "AAPL"}).
MetadataFilters = dict[str, Any]


def build_index_mapping(embedding_dimensions: int) -> dict[str, Any]:
    """Return the hybrid index mapping (k-NN vector + analyzed text)."""
    return {
        "settings": {
            "index": {"knn": True, "number_of_shards": 1, "number_of_replicas": 0},
        },
        "mappings": {
            "properties": {
                "chunk_id": {"type": "keyword"},
                "tenant_id": {"type": "keyword"},
                "filing_id": {"type": "keyword"},
                "cik": {"type": "keyword"},
                "ticker": {"type": "keyword"},
                "company_name": {"type": "text"},
                "form": {"type": "keyword"},
                "filing_date": {"type": "date"},
                "source_url": {"type": "keyword"},
                "section": {"type": "keyword"},
                "chunk_index": {"type": "integer"},
                "text": {"type": "text", "analyzer": "english"},
                "embedding": {
                    "type": "knn_vector",
                    "dimension": embedding_dimensions,
                    "method": {
                        "name": "hnsw",
                        "space_type": "cosinesimil",
                        "engine": "lucene",
                    },
                },
            }
        },
    }


class VectorStore(Protocol):
    """Interface for indexing and searching chunks.

    Every operation is scoped to a ``TenantContext``. For OpenSearch this maps
    to a per-tenant index; for the in-memory store it filters by tenant_id. A
    tenant can therefore never retrieve another tenant's chunks.
    """

    def ensure_index(self, tenant: TenantContext) -> None: ...

    def index_chunks(self, tenant: TenantContext, chunks: list[Chunk]) -> int: ...

    def keyword_search(
        self, tenant: TenantContext, query: str, top_k: int, filters: MetadataFilters | None = None
    ) -> list[SearchHit]: ...

    def vector_search(
        self, tenant: TenantContext, embedding: list[float], top_k: int, filters: MetadataFilters | None = None
    ) -> list[SearchHit]: ...


# ---------------------------------------------------------------------------
# Real OpenSearch implementation
# ---------------------------------------------------------------------------
class OpenSearchStore:
    """Amazon OpenSearch (or local docker OpenSearch) backed store."""

    def __init__(self, settings: Settings) -> None:
        from opensearchpy import OpenSearch

        self._settings = settings
        self._client = OpenSearch(
            hosts=[{"host": settings.opensearch_host, "port": settings.opensearch_port}],
            http_auth=(settings.opensearch_user, settings.opensearch_password),
            use_ssl=settings.opensearch_use_ssl,
            verify_certs=False,
            ssl_show_warn=False,
        )

    def ensure_index(self, tenant: TenantContext) -> None:
        index = tenant.index_name(self._settings)
        if not self._client.indices.exists(index=index):
            self._client.indices.create(index=index, body=build_index_mapping(self._settings.embedding_dimensions))
            logger.info("Created OpenSearch index", index=index, **tenant.log_fields())

    def index_chunks(self, tenant: TenantContext, chunks: list[Chunk]) -> int:
        from opensearchpy.helpers import bulk

        index = tenant.index_name(self._settings)
        # Guard: refuse to index a chunk whose tenant_id != the target tenant.
        for c in chunks:
            if c.tenant_id != tenant.tenant_id:
                raise ValueError("Refusing to index chunk from a different tenant")
        actions = [{"_index": index, "_id": c.chunk_id, "_source": c.to_opensearch_doc()} for c in chunks]
        success, _ = bulk(self._client, actions, refresh=True)
        return success

    def _filter_clauses(self, tenant: TenantContext, filters: MetadataFilters | None) -> list[dict]:
        # Always include the tenant term as defense-in-depth on top of the
        # per-tenant index (so even a mis-routed query cannot cross tenants).
        clauses: list[dict] = [{"term": {"tenant_id": tenant.tenant_id}}]
        for field, value in (filters or {}).items():
            clauses.append({"term": {field: value}})
        return clauses

    def keyword_search(
        self, tenant: TenantContext, query: str, top_k: int, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        body = {
            "size": top_k,
            "query": {
                "bool": {
                    "must": [{"match": {"text": query}}],
                    "filter": self._filter_clauses(tenant, filters),
                }
            },
        }
        return self._to_hits(self._client.search(index=tenant.index_name(self._settings), body=body))

    def vector_search(
        self, tenant: TenantContext, embedding: list[float], top_k: int, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        body = {
            "size": top_k,
            "query": {
                "bool": {
                    "must": [{"knn": {"embedding": {"vector": embedding, "k": top_k}}}],
                    "filter": self._filter_clauses(tenant, filters),
                }
            },
        }
        return self._to_hits(self._client.search(index=tenant.index_name(self._settings), body=body))

    @staticmethod
    def _to_hits(resp: dict) -> list[SearchHit]:
        hits: list[SearchHit] = []
        for h in resp.get("hits", {}).get("hits", []):
            src = h["_source"]
            hits.append(
                SearchHit(
                    chunk_id=src["chunk_id"], tenant_id=src.get("tenant_id", ""), filing_id=src["filing_id"],
                    ticker=src.get("ticker"), company_name=src["company_name"], form=src["form"],
                    filing_date=src["filing_date"], section=src.get("section"), source_url=src["source_url"],
                    text=src["text"], score=float(h.get("_score", 0.0)),
                )
            )
        return hits


# ---------------------------------------------------------------------------
# In-memory implementation (offline dev / tests)
# ---------------------------------------------------------------------------
class InMemoryVectorStore:
    """Brute-force cosine + term-overlap store; mirrors OpenSearchStore.

    Documents are tagged with tenant_id; every query filters by the requesting
    tenant so cross-tenant retrieval is impossible even in local mode.
    """

    _docs: list[Chunk] = []

    def ensure_index(self, tenant: TenantContext) -> None:
        return None

    def index_chunks(self, tenant: TenantContext, chunks: list[Chunk]) -> int:
        for c in chunks:
            if c.tenant_id != tenant.tenant_id:
                raise ValueError("Refusing to index chunk from a different tenant")
        InMemoryVectorStore._docs.extend(chunks)
        return len(chunks)

    def _candidates(self, tenant: TenantContext, filters: MetadataFilters | None) -> list[Chunk]:
        out = [c for c in InMemoryVectorStore._docs if c.tenant_id == tenant.tenant_id]
        for field, value in (filters or {}).items():
            out = [c for c in out if getattr(c, field, None) == value]
        return out

    def keyword_search(
        self, tenant: TenantContext, query: str, top_k: int, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        terms = set(query.lower().split())
        scored: list[tuple[float, Chunk]] = []
        for c in self._candidates(tenant, filters):
            doc_terms = c.text.lower().split()
            overlap = sum(1 for t in doc_terms if t in terms)
            if overlap:
                scored.append((overlap / (len(doc_terms) ** 0.5 or 1), c))
        scored.sort(key=lambda x: x[0], reverse=True)
        return [_chunk_to_hit(c, s) for s, c in scored[:top_k]]

    def vector_search(
        self, tenant: TenantContext, embedding: list[float], top_k: int, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        scored: list[tuple[float, Chunk]] = []
        for c in self._candidates(tenant, filters):
            if c.embedding:
                scored.append((_cosine(embedding, c.embedding), c))
        scored.sort(key=lambda x: x[0], reverse=True)
        return [_chunk_to_hit(c, s) for s, c in scored[:top_k]]


def _cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=False))
    na = math.sqrt(sum(x * x for x in a)) or 1.0
    nb = math.sqrt(sum(y * y for y in b)) or 1.0
    return dot / (na * nb)


def _chunk_to_hit(c: Chunk, score: float) -> SearchHit:
    return SearchHit(
        chunk_id=c.chunk_id, tenant_id=c.tenant_id, filing_id=c.filing_id, ticker=c.ticker,
        company_name=c.company_name, form=c.form.value, filing_date=c.filing_date.isoformat(),
        section=c.section, source_url=c.source_url, text=c.text, score=float(score),
    )


def get_vector_store(settings: Settings | None = None) -> VectorStore:
    """Return an OpenSearch or in-memory store based on run mode."""
    settings = settings or get_settings()
    if settings.run_mode == RunMode.AWS:
        try:
            # Index creation is per-tenant, done lazily by the worker/search layer.
            return OpenSearchStore(settings)
        except Exception as exc:  # pragma: no cover - env dependent
            logger.warning("OpenSearch unavailable, using in-memory store", error=str(exc))
    return InMemoryVectorStore()


__all__ = ["VectorStore", "OpenSearchStore", "InMemoryVectorStore", "get_vector_store", "build_index_mapping"]

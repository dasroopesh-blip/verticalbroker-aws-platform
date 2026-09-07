"""Search service: the multi-stage, tenant-scoped ranking funnel.

Pipeline for hybrid search:

    Stage 1  RETRIEVE   BM25 keyword + kNN vector (over-fetch candidates)
    Stage 2  FUSE       Reciprocal Rank Fusion (combine the two rankings)
    Stage 3  RERANK     cross-encoder re-scores the shortlist (SageMaker/local)

Every call is scoped to a ``TenantContext`` — the store targets the tenant's
index (Bridge model) and applies a tenant filter, so no query can return
another tenant's data. Optional metadata filters (ticker, form, date, section)
narrow retrieval further.

Reciprocal Rank Fusion combines *rankings*, not raw scores (BM25 and cosine are
on different scales):

    RRF(d) = Σ  1 / (k + rank_d)      across result lists (k = 60)
"""

from __future__ import annotations

from filings_assistant.common.bedrock import BedrockClient, get_bedrock_client
from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.common.tenant import TenantContext
from filings_assistant.models import SearchHit
from filings_assistant.search.opensearch_store import MetadataFilters, VectorStore, get_vector_store
from filings_assistant.search.reranker import Reranker, get_reranker

logger = get_logger("search.service")

_RRF_K = 60  # standard RRF constant; larger = flatter rank weighting


class SearchService:
    """Tenant-scoped keyword, semantic, and hybrid search with reranking."""

    def __init__(
        self,
        settings: Settings | None = None,
        store: VectorStore | None = None,
        bedrock: BedrockClient | None = None,
        reranker: Reranker | None = None,
    ) -> None:
        self._settings = settings or get_settings()
        self._store = store or get_vector_store(self._settings)
        self._bedrock = bedrock or get_bedrock_client(self._settings)
        self._reranker = reranker or get_reranker(self._settings)

    def keyword_search(
        self, tenant: TenantContext, query: str, top_k: int | None = None, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        """BM25 keyword search (tenant-scoped)."""
        return self._store.keyword_search(tenant, query, top_k or self._settings.top_k, filters)

    def semantic_search(
        self, tenant: TenantContext, query: str, top_k: int | None = None, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        """Embed the query and run tenant-scoped k-NN vector search."""
        embedding = self._bedrock.embed_texts([query])[0]
        return self._store.vector_search(tenant, embedding, top_k or self._settings.top_k, filters)

    def hybrid_search(
        self, tenant: TenantContext, query: str, top_k: int | None = None, filters: MetadataFilters | None = None
    ) -> list[SearchHit]:
        """Retrieve → fuse (RRF) → rerank. Returns the final tenant-scoped ranking."""
        k = top_k or self._settings.top_k
        shortlist_n = max(self._settings.rerank_candidates, k)

        # Stage 1: retrieve candidates from both signals (over-fetch for fusion).
        keyword_hits = self.keyword_search(tenant, query, top_k=shortlist_n, filters=filters)
        semantic_hits = self.semantic_search(tenant, query, top_k=shortlist_n, filters=filters)

        # Stage 2: fuse rankings.
        fused = _reciprocal_rank_fusion([keyword_hits, semantic_hits])[:shortlist_n]

        # Stage 3: rerank the shortlist for precision, return top k.
        reranked = self._reranker.rerank(query, fused, top_k=k)
        logger.info(
            "hybrid_search complete",
            candidates=len(fused),
            returned=len(reranked),
            **tenant.log_fields(),
        )
        return reranked


def _reciprocal_rank_fusion(result_lists: list[list[SearchHit]]) -> list[SearchHit]:
    """Combine multiple ranked lists into one via RRF, deduping by chunk_id."""
    scores: dict[str, float] = {}
    by_id: dict[str, SearchHit] = {}
    for hits in result_lists:
        for rank, hit in enumerate(hits):
            scores[hit.chunk_id] = scores.get(hit.chunk_id, 0.0) + 1.0 / (_RRF_K + rank)
            by_id.setdefault(hit.chunk_id, hit)
    ordered = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    return [by_id[cid].model_copy(update={"score": round(score, 6)}) for cid, score in ordered]

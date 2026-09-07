"""Evaluation runner: score retrieval quality, with and without reranking.

Given a set of labeled queries (each with the chunk_ids that are truly relevant),
this runs the search pipeline and computes Recall@k, MRR, and nDCG@k. It can run
the same queries with reranking OFF vs ON to demonstrate the ranking uplift the
cross-encoder provides — the core "how good is our ranking" evidence.

The golden dataset here is small and illustrative (built on the offline sample
filings). In practice you would curate a domain-specific set of analyst
questions with human-labeled relevant passages per tenant.
"""

from __future__ import annotations

from dataclasses import dataclass

from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.common.tenant import TenantContext
from filings_assistant.evaluation.metrics import aggregate, ndcg_at_k, recall_at_k, reciprocal_rank
from filings_assistant.search.reranker import LocalReranker, NoOpReranker
from filings_assistant.search.service import SearchService

logger = get_logger("evaluation.harness")


@dataclass
class LabeledQuery:
    """A query with the set of chunk_ids considered relevant."""

    query: str
    relevant_chunk_ids: set[str]


def evaluate(
    tenant: TenantContext,
    queries: list[LabeledQuery],
    settings: Settings | None = None,
    k: int = 5,
    use_reranker: bool = True,
) -> dict[str, float]:
    """Run the queries and return aggregate Recall@k / MRR / nDCG@k."""
    settings = settings or get_settings()
    reranker = LocalReranker() if use_reranker else NoOpReranker()
    service = SearchService(settings=settings, reranker=reranker)

    per_query: list[dict[str, float]] = []
    for lq in queries:
        hits = service.hybrid_search(tenant, lq.query, top_k=k)
        ranked_ids = [h.chunk_id for h in hits]
        per_query.append(
            {
                f"recall@{k}": recall_at_k(ranked_ids, lq.relevant_chunk_ids, k),
                "mrr": reciprocal_rank(ranked_ids, lq.relevant_chunk_ids),
                f"ndcg@{k}": ndcg_at_k(ranked_ids, lq.relevant_chunk_ids, k),
            }
        )
    result = aggregate(per_query)
    logger.info("evaluation complete", reranker=use_reranker, **{k2: round(v, 4) for k2, v in result.items()})
    return result


def compare_reranking(tenant: TenantContext, queries: list[LabeledQuery], k: int = 5) -> dict[str, dict[str, float]]:
    """Return metrics with reranking OFF vs ON for a before/after comparison."""
    return {
        "without_reranking": evaluate(tenant, queries, k=k, use_reranker=False),
        "with_reranking": evaluate(tenant, queries, k=k, use_reranker=True),
    }


__all__ = ["LabeledQuery", "evaluate", "compare_reranking"]

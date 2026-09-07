"""Information-retrieval quality metrics.

These quantify *how good* the ranking is against a set of known-relevant
documents (the "golden" set). They are the objective way to answer "how
relevant is our search?" and to prove that changes (e.g. adding the reranker)
actually improve results rather than just feeling better.

Implemented (all standard IR metrics):
    - recall_at_k : fraction of relevant items found in the top k
    - mrr         : Mean Reciprocal Rank — 1/rank of the first relevant hit
    - ndcg_at_k   : Normalized Discounted Cumulative Gain — rewards putting
                    relevant items higher, discounted by log position
"""

from __future__ import annotations

import math
from collections.abc import Sequence


def recall_at_k(ranked_ids: Sequence[str], relevant_ids: set[str], k: int) -> float:
    """Fraction of relevant items appearing in the top-k results."""
    if not relevant_ids:
        return 0.0
    top = set(ranked_ids[:k])
    return len(top & relevant_ids) / len(relevant_ids)


def reciprocal_rank(ranked_ids: Sequence[str], relevant_ids: set[str]) -> float:
    """1 / (rank of first relevant hit), or 0 if none present."""
    for i, rid in enumerate(ranked_ids, start=1):
        if rid in relevant_ids:
            return 1.0 / i
    return 0.0


def ndcg_at_k(ranked_ids: Sequence[str], relevant_ids: set[str], k: int) -> float:
    """Normalized DCG at k with binary relevance (1 if relevant else 0)."""
    dcg = 0.0
    for i, rid in enumerate(ranked_ids[:k], start=1):
        if rid in relevant_ids:
            dcg += 1.0 / math.log2(i + 1)
    ideal_hits = min(len(relevant_ids), k)
    idcg = sum(1.0 / math.log2(i + 1) for i in range(1, ideal_hits + 1))
    return dcg / idcg if idcg > 0 else 0.0


def aggregate(per_query: list[dict[str, float]]) -> dict[str, float]:
    """Average each metric across queries."""
    if not per_query:
        return {}
    keys = per_query[0].keys()
    return {key: sum(q[key] for q in per_query) / len(per_query) for key in keys}


__all__ = ["recall_at_k", "reciprocal_rank", "ndcg_at_k", "aggregate"]

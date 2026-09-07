"""Reranking stage — the precision step of the ranking funnel.

First-stage retrieval (BM25 + kNN, fused with RRF) is fast but coarse: it gets
the right ~50 candidates into the shortlist but doesn't order them perfectly.
A **cross-encoder reranker** re-scores each (query, passage) pair *jointly*,
capturing interactions (exact overlap, negation, entity resolution) that a
bi-encoder / vector similarity cannot. It runs only on the shortlist, so the
expensive step stays cheap.

Backends:
    - ``SageMakerReranker`` — invokes a SageMaker endpoint hosting a cross-encoder
      (e.g. a fine-tuned MS-MARCO / BGE reranker). Used in AWS mode.
    - ``LocalReranker`` — a dependency-free lexical cross-scorer used offline and
      in tests. It is deterministic and good enough to demonstrate that
      reranking reorders results by query-passage relevance.

The reranker is tenant-agnostic and safe to share across tenants: it only ever
sees the shortlist passed to it (already tenant-filtered by the search layer)
and retains nothing between calls.
"""

from __future__ import annotations

import math
import re
from typing import Protocol

from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.models import SearchHit

logger = get_logger("search.reranker")

_WORD_RE = re.compile(r"[a-z0-9]+")


def _tokenize(text: str) -> list[str]:
    return _WORD_RE.findall(text.lower())


class Reranker(Protocol):
    """Reorders search hits by (query, passage) relevance."""

    def rerank(self, query: str, hits: list[SearchHit], top_k: int) -> list[SearchHit]: ...


class SageMakerReranker:
    """Cross-encoder reranker hosted on an Amazon SageMaker endpoint."""

    def __init__(self, settings: Settings) -> None:
        import boto3

        self._settings = settings
        self._endpoint = settings.sagemaker_reranker_endpoint
        self._runtime = boto3.client("sagemaker-runtime", region_name=settings.aws_region)

    def rerank(self, query: str, hits: list[SearchHit], top_k: int) -> list[SearchHit]:
        if not hits:
            return []
        import json

        payload = {"query": query, "passages": [h.text for h in hits]}
        resp = self._runtime.invoke_endpoint(
            EndpointName=self._endpoint, ContentType="application/json", Body=json.dumps(payload)
        )
        # Endpoint returns a relevance score per passage, aligned to input order.
        scores = json.loads(resp["Body"].read())["scores"]
        rescored = [h.model_copy(update={"score": float(s)}) for h, s in zip(hits, scores, strict=True)]
        rescored.sort(key=lambda h: h.score, reverse=True)
        return rescored[:top_k]


class LocalReranker:
    """Offline cross-scorer: a lightweight lexical proxy for a cross-encoder.

    Scores each passage against the query using overlap of query terms weighted
    by inverse passage length, plus a phrase-adjacency bonus. Deterministic;
    reorders by joint query-passage signal (not just first-stage score).
    """

    def rerank(self, query: str, hits: list[SearchHit], top_k: int) -> list[SearchHit]:
        q_terms = _tokenize(query)
        q_set = set(q_terms)
        rescored: list[SearchHit] = []
        for h in hits:
            p_terms = _tokenize(h.text)
            if not p_terms:
                rescored.append(h.model_copy(update={"score": 0.0}))
                continue
            overlap = sum(1 for t in p_terms if t in q_set)
            coverage = len({t for t in p_terms if t in q_set}) / (len(q_set) or 1)
            phrase_bonus = _phrase_adjacency_bonus(q_terms, p_terms)
            # Length-normalized relevance; coverage rewards hitting more query terms.
            score = (overlap / math.sqrt(len(p_terms))) * (1.0 + coverage) + phrase_bonus
            rescored.append(h.model_copy(update={"score": round(score, 6)}))
        rescored.sort(key=lambda h: h.score, reverse=True)
        return rescored[:top_k]


def _phrase_adjacency_bonus(q_terms: list[str], p_terms: list[str]) -> float:
    """Small bonus when consecutive query terms appear adjacently in the passage."""
    if len(q_terms) < 2:
        return 0.0
    p_bigrams = set(zip(p_terms, p_terms[1:], strict=False))
    q_bigrams = set(zip(q_terms, q_terms[1:], strict=False))
    return 0.25 * len(p_bigrams & q_bigrams)


class NoOpReranker:
    """Passthrough used when reranking is disabled."""

    def rerank(self, query: str, hits: list[SearchHit], top_k: int) -> list[SearchHit]:
        return hits[:top_k]


def get_reranker(settings: Settings | None = None) -> Reranker:
    """Return the configured reranker.

    - reranking disabled          -> NoOpReranker
    - AWS mode + endpoint set      -> SageMakerReranker (falls back on error)
    - otherwise                    -> LocalReranker
    """
    settings = settings or get_settings()
    if not settings.enable_reranking:
        return NoOpReranker()
    from filings_assistant.common.config import RunMode

    if settings.run_mode == RunMode.AWS and settings.sagemaker_reranker_endpoint:
        try:
            return SageMakerReranker(settings)
        except Exception as exc:  # pragma: no cover - env dependent
            logger.warning("SageMaker reranker unavailable, using local reranker", error=str(exc))
    return LocalReranker()


__all__ = ["Reranker", "SageMakerReranker", "LocalReranker", "NoOpReranker", "get_reranker"]

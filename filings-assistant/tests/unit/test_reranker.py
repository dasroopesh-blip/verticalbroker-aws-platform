"""Unit tests for the reranking stage."""

from __future__ import annotations

import pytest

from filings_assistant.models import SearchHit
from filings_assistant.search.reranker import LocalReranker, NoOpReranker

pytestmark = pytest.mark.unit


def _hit(chunk_id: str, text: str, score: float) -> SearchHit:
    return SearchHit(
        chunk_id=chunk_id, tenant_id="t", filing_id="f", ticker="AAPL", company_name="Apple",
        form="10-K", filing_date="2024-01-01", section=None, source_url="http://x", text=text, score=score,
    )


def test_local_reranker_promotes_more_relevant_passage() -> None:
    query = "supply chain concentration risk"
    hits = [
        _hit("a", "The company pays quarterly dividends to shareholders.", 10.0),
        _hit("b", "Supply chain concentration risk from outsourcing partners is material.", 0.1),
    ]
    reranked = LocalReranker().rerank(query, hits, top_k=2)
    # Despite a lower first-stage score, the on-topic passage should rank first.
    assert reranked[0].chunk_id == "b"


def test_local_reranker_respects_top_k() -> None:
    query = "risk"
    hits = [_hit(str(i), f"risk factor number {i}", 1.0) for i in range(10)]
    assert len(LocalReranker().rerank(query, hits, top_k=3)) == 3


def test_noop_reranker_preserves_order() -> None:
    hits = [_hit("a", "x", 3.0), _hit("b", "y", 2.0)]
    out = NoOpReranker().rerank("q", hits, top_k=5)
    assert [h.chunk_id for h in out] == ["a", "b"]


def test_reranker_handles_empty() -> None:
    assert LocalReranker().rerank("q", [], top_k=5) == []

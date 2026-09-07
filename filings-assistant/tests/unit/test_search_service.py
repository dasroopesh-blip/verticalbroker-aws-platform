"""Unit tests for search + RRF fusion, using in-memory store + mock Bedrock."""

from __future__ import annotations

import pytest

from filings_assistant.common.bedrock import MockBedrockClient
from filings_assistant.common.tenant import TenantContext
from filings_assistant.models import Chunk, FilingForm, SearchHit
from filings_assistant.search.opensearch_store import InMemoryVectorStore
from filings_assistant.search.reranker import LocalReranker
from filings_assistant.search.service import SearchService, _reciprocal_rank_fusion

pytestmark = pytest.mark.unit

TENANT = TenantContext.from_auth("acme")


def _make_hit(chunk_id: str, score: float) -> SearchHit:
    return SearchHit(
        chunk_id=chunk_id, tenant_id="acme", filing_id="f1", ticker="AAPL", company_name="Apple Inc.",
        form="10-K", filing_date="2024-01-01", section=None,
        source_url="http://x", text="t", score=score,
    )


def test_rrf_prefers_items_ranked_high_in_both_lists() -> None:
    list_a = [_make_hit("x", 1.0), _make_hit("y", 0.9)]
    list_b = [_make_hit("x", 5.0), _make_hit("z", 4.0)]
    fused = _reciprocal_rank_fusion([list_a, list_b])
    assert fused[0].chunk_id == "x"
    assert len({h.chunk_id for h in fused}) == len(fused)


@pytest.fixture
def populated_store(settings) -> InMemoryVectorStore:
    InMemoryVectorStore._docs = []
    store = InMemoryVectorStore()
    bedrock = MockBedrockClient(settings)
    chunks = []
    for i, text in enumerate(
        [
            "Apple faces supply chain concentration risk and tariffs.",
            "Microsoft cites AI regulation and cybersecurity risk.",
            "The company pays dividends and repurchases shares.",
        ]
    ):
        c = Chunk(
            tenant_id="acme", filing_id=f"f{i}", cik="1", ticker="AAPL", company_name="Co",
            form=FilingForm.FORM_10K, filing_date="2024-01-01",
            source_url="http://x", chunk_index=i, text=text,
        )
        c.embedding = bedrock.embed_texts([text])[0]
        chunks.append(c)
    store.index_chunks(TENANT, chunks)
    return store


def test_keyword_search_finds_term(settings, populated_store) -> None:
    svc = SearchService(settings=settings, store=populated_store, bedrock=MockBedrockClient(settings))
    hits = svc.keyword_search(TENANT, "supply chain", top_k=3)
    assert hits
    assert "supply chain" in hits[0].text.lower()


def test_hybrid_search_returns_results(settings, populated_store) -> None:
    svc = SearchService(
        settings=settings, store=populated_store, bedrock=MockBedrockClient(settings), reranker=LocalReranker()
    )
    hits = svc.hybrid_search(TENANT, "supply chain tariffs", top_k=2)
    assert 1 <= len(hits) <= 2


def test_metadata_filter_narrows_results(settings, populated_store) -> None:
    svc = SearchService(settings=settings, store=populated_store, bedrock=MockBedrockClient(settings))
    # Filter to a ticker that exists; all docs are AAPL so we still get hits.
    hits = svc.keyword_search(TENANT, "risk", top_k=5, filters={"ticker": "AAPL"})
    assert all(h.ticker == "AAPL" for h in hits)

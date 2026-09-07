"""End-to-end smoke test of the offline (local + mock) pipeline.

Runs the full flow with zero external dependencies (FA_RUN_MODE=local,
FA_USE_MOCK_BEDROCK=true):

    ingest (offline SEC samples) -> store -> queue -> worker (chunk + mock
    embed + in-memory index) -> hybrid search -> agent answer with citations.

Usage:
    python scripts/smoke_test.py

Exits non-zero if any stage fails. This is the quickest way to confirm the
wiring after installing deps (`pip install -e ".[dev]"`).
"""

from __future__ import annotations

import os
import sys

# Force fully-offline mode before importing the app.
os.environ.setdefault("FA_RUN_MODE", "local")
os.environ.setdefault("FA_USE_MOCK_BEDROCK", "true")


def main() -> int:
    from filings_assistant.agent.agent import FilingsAgent
    from filings_assistant.common.tenant import TenantContext
    from filings_assistant.ingestion.service import IngestionService
    from filings_assistant.models import FilingForm
    from filings_assistant.search.service import SearchService
    from filings_assistant.worker.processor import WorkerProcessor

    tenant = TenantContext.from_auth("demo-tenant")

    print("1) Ingesting sample filings (AAPL, MSFT 10-K) for tenant 'demo-tenant'...")
    ingestion = IngestionService()
    stored = ingestion.ingest(tenant, "AAPL", FilingForm.FORM_10K, limit=1)
    stored += ingestion.ingest(tenant, "MSFT", FilingForm.FORM_10K, limit=1)
    assert stored, "expected filings to be ingested"
    print(f"   ingested {len(stored)} filings")

    print("2) Running worker (chunk + embed + index)...")
    indexed = WorkerProcessor().drain()
    assert indexed >= 1, "expected worker to index filings"
    print(f"   indexed {indexed} filings")

    print("3) Hybrid search (retrieve -> RRF -> rerank): 'supply chain risk'...")
    hits = SearchService().hybrid_search(tenant, "supply chain risk", top_k=3)
    assert hits, "expected search hits"
    for h in hits:
        print(f"   [{h.score:.4f}] {h.citation()}")

    print("4) Agent question (tenant-scoped)...")
    answer = FilingsAgent(tenant=tenant).ask("What supply chain risks does Apple cite?")
    assert answer.answer, "expected a non-empty answer"
    print(f"   answer: {answer.answer[:160]}...")
    print(f"   citations: {answer.citations}")

    print("5) Tenant isolation check: a different tenant must see NOTHING...")
    other = TenantContext.from_auth("other-tenant")
    other_hits = SearchService().hybrid_search(other, "supply chain risk", top_k=3)
    assert other_hits == [], "ISOLATION FAILURE: another tenant saw this tenant's data"
    print("   other tenant correctly saw 0 results ✅")

    print("\nSMOKE TEST PASSED ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())

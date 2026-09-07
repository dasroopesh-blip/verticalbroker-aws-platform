"""End-to-end unit test of the offline pipeline (ingest → index → search → agent)."""

from __future__ import annotations

import pytest

from filings_assistant.agent.agent import FilingsAgent
from filings_assistant.common.tenant import TenantContext
from filings_assistant.ingestion.service import IngestionService
from filings_assistant.models import FilingForm
from filings_assistant.search.opensearch_store import InMemoryVectorStore
from filings_assistant.worker.processor import WorkerProcessor

pytestmark = pytest.mark.unit

TENANT = TenantContext.from_auth("acme")


@pytest.fixture(autouse=True)
def _reset_store() -> None:
    InMemoryVectorStore._docs = []


def test_full_offline_pipeline() -> None:
    stored = IngestionService().ingest(TENANT, "AAPL", FilingForm.FORM_10K, limit=1)
    assert stored

    indexed = WorkerProcessor().drain()
    assert indexed >= 1

    answer = FilingsAgent(tenant=TENANT).ask("What supply chain risks does Apple cite?")
    assert answer.answer
    assert answer.steps >= 1


def test_ingest_is_idempotent() -> None:
    svc = IngestionService()
    first = svc.ingest(TENANT, "MSFT", FilingForm.FORM_10K, limit=1)
    second = svc.ingest(TENANT, "MSFT", FilingForm.FORM_10K, limit=1)
    assert first
    assert second == []  # duplicate checksum for same tenant -> nothing new


def test_same_filing_different_tenants_both_ingest() -> None:
    svc = IngestionService()
    tenant_a = TenantContext.from_auth("bank-a")
    tenant_b = TenantContext.from_auth("bank-b")
    a = svc.ingest(tenant_a, "AAPL", FilingForm.FORM_10K, limit=1)
    b = svc.ingest(tenant_b, "AAPL", FilingForm.FORM_10K, limit=1)
    # The same public filing is independently owned by each tenant.
    assert a and b

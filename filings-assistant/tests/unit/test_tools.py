"""Unit tests for the shared tool registry and Bedrock tool specs."""

from __future__ import annotations

import pytest

from filings_assistant.common.tenant import TenantContext
from filings_assistant.mcp_server.tools import TOOL_SCHEMAS, ToolRegistry, bedrock_tool_specs
from filings_assistant.search.opensearch_store import InMemoryVectorStore

pytestmark = pytest.mark.unit

TENANT = TenantContext.from_auth("acme")


@pytest.fixture(autouse=True)
def _reset_store() -> None:
    InMemoryVectorStore._docs = []


def test_registry_exposes_all_schema_tools() -> None:
    registry = ToolRegistry(tenant=TENANT)
    assert set(registry.names) == set(TOOL_SCHEMAS)


def test_unknown_tool_returns_error() -> None:
    result = ToolRegistry(tenant=TENANT).call("does_not_exist", {})
    assert "error" in result


def test_no_tool_schema_exposes_tenant_id() -> None:
    # Critical: the LLM must never be able to specify a tenant.
    for spec in TOOL_SCHEMAS.values():
        assert "tenant_id" not in spec["input_schema"].get("properties", {})


def test_ingest_then_search_via_tools() -> None:
    registry = ToolRegistry(tenant=TENANT)
    ingest_result = registry.call("ingest_filing", {"ticker": "AAPL", "form": "10-K", "limit": 1})
    assert ingest_result["ingested"] >= 1

    search_result = registry.call("hybrid_search", {"query": "supply chain risk", "top_k": 3})
    assert search_result["count"] >= 1
    assert "citation" in search_result["results"][0]


def test_bedrock_tool_specs_shape() -> None:
    specs = bedrock_tool_specs()
    assert specs
    for spec in specs:
        assert "toolSpec" in spec
        assert "name" in spec["toolSpec"]
        assert "inputSchema" in spec["toolSpec"]

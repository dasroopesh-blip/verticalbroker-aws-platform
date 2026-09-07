"""Tool definitions and handlers for the Filings Assistant.

These tools are the single source of truth for the system's capabilities. They
are framework-agnostic: the MCP server exposes them over the Model Context
Protocol, and the in-process agent calls the very same handlers via
``ToolRegistry``. That guarantees the agent and external MCP clients behave
identically.

Each tool provides:
    - a JSON-schema input spec (used by both MCP and Bedrock tool-use),
    - a handler that returns a JSON-serializable dict.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from filings_assistant.common.logging import get_logger
from filings_assistant.common.storage import get_repository
from filings_assistant.common.tenant import TenantContext
from filings_assistant.ingestion.service import IngestionService
from filings_assistant.models import FilingForm, SearchHit
from filings_assistant.search.service import SearchService

logger = get_logger("mcp.tools")


# ---------------------------------------------------------------------------
# Tool schemas (JSON Schema). Shared by MCP + Bedrock converse tool-use.
# ---------------------------------------------------------------------------
def _search_schema(desc: str) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Natural-language search query."},
            "top_k": {"type": "integer", "description": "Number of results to return.", "default": 6},
        },
        "required": ["query"],
    }


TOOL_SCHEMAS: dict[str, dict[str, Any]] = {
    "ingest_filing": {
        "description": "Fetch a company's SEC filing, store it, and index it for search.",
        "input_schema": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string", "description": "Ticker symbol, e.g. AAPL."},
                "form": {"type": "string", "enum": [f.value for f in FilingForm], "default": "10-K"},
                "limit": {"type": "integer", "default": 1},
            },
            "required": ["ticker"],
        },
    },
    "keyword_search": {
        "description": "BM25 keyword search over indexed filings. Best for exact terms/phrases.",
        "input_schema": _search_schema("keyword"),
    },
    "semantic_search": {
        "description": "Vector (meaning-based) search over filings. Best for conceptual questions.",
        "input_schema": _search_schema("semantic"),
    },
    "hybrid_search": {
        "description": "Combined keyword + semantic search (recommended default for retrieval).",
        "input_schema": _search_schema("hybrid"),
    },
    "get_document": {
        "description": "Retrieve a stored filing's metadata and text by filing_id.",
        "input_schema": {
            "type": "object",
            "properties": {"filing_id": {"type": "string"}},
            "required": ["filing_id"],
        },
    },
    "list_filings": {
        "description": "List filings currently stored, with their ingest status.",
        "input_schema": {
            "type": "object",
            "properties": {"limit": {"type": "integer", "default": 20}},
        },
    },
}


def _hits_to_payload(hits: list[SearchHit]) -> dict[str, Any]:
    return {
        "count": len(hits),
        "results": [
            {
                "chunk_id": h.chunk_id,
                "filing_id": h.filing_id,
                "citation": h.citation(),
                "source_url": h.source_url,
                "score": h.score,
                "text": h.text,
            }
            for h in hits
        ],
    }


class ToolRegistry:
    """Holds the tool handlers and dispatches calls by name.

    SECURITY: a registry is bound to exactly one ``TenantContext`` at
    construction. Handlers inject that tenant into every storage/search call.
    Tool *schemas* expose no ``tenant_id`` parameter, so the LLM has no way to
    specify or change the tenant — cross-tenant access is impossible by
    construction, even under prompt injection.
    """

    def __init__(
        self,
        tenant: TenantContext,
        search_service: SearchService | None = None,
        ingestion_service: IngestionService | None = None,
    ) -> None:
        self._tenant = tenant
        self._search = search_service or SearchService()
        self._ingest = ingestion_service or IngestionService()
        self._handlers: dict[str, Callable[..., dict[str, Any]]] = {
            "ingest_filing": self._ingest_filing,
            "keyword_search": self._keyword_search,
            "semantic_search": self._semantic_search,
            "hybrid_search": self._hybrid_search,
            "get_document": self._get_document,
            "list_filings": self._list_filings,
        }

    @property
    def names(self) -> list[str]:
        return list(self._handlers)

    @property
    def search_service(self) -> SearchService:
        """The underlying search service (used by the agent's fallback path)."""
        return self._search

    def call(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """Dispatch a tool call by name; never raises to the caller."""
        handler = self._handlers.get(name)
        if handler is None:
            return {"error": f"Unknown tool: {name}"}
        try:
            return handler(**arguments)
        except Exception as exc:  # tools must return errors, not crash the agent
            logger.error("Tool call failed", tool=name, error=str(exc))
            return {"error": str(exc)}

    # -- handlers (tenant is injected from self._tenant, never from args) ----
    def _ingest_filing(self, ticker: str, form: str = "10-K", limit: int = 1) -> dict[str, Any]:
        stored = self._ingest.ingest(self._tenant, ticker, FilingForm(form), limit)
        # Index immediately so results are queryable right after ingest.
        from filings_assistant.worker.processor import WorkerProcessor

        indexed = WorkerProcessor().drain()
        return {
            "ingested": len(stored),
            "indexed": indexed,
            "filings": [{"filing_id": f.filing_id, "company": f.company_name} for f in stored],
        }

    def _keyword_search(self, query: str, top_k: int = 6) -> dict[str, Any]:
        return _hits_to_payload(self._search.keyword_search(self._tenant, query, top_k))

    def _semantic_search(self, query: str, top_k: int = 6) -> dict[str, Any]:
        return _hits_to_payload(self._search.semantic_search(self._tenant, query, top_k))

    def _hybrid_search(self, query: str, top_k: int = 6) -> dict[str, Any]:
        return _hits_to_payload(self._search.hybrid_search(self._tenant, query, top_k))

    def _get_document(self, filing_id: str) -> dict[str, Any]:
        filing = get_repository().get_filing(self._tenant.tenant_id, filing_id)
        if filing is None:
            return {"error": f"Filing not found: {filing_id}"}
        return {
            "filing_id": filing.filing_id,
            "company_name": filing.company_name,
            "ticker": filing.ticker,
            "form": filing.form.value,
            "filing_date": filing.filing_date.isoformat(),
            "status": filing.status.value,
            "source_url": filing.source_url,
            "text_preview": filing.raw_text[:2000],
        }

    def _list_filings(self, limit: int = 20) -> dict[str, Any]:
        filings = get_repository().list_filings(self._tenant.tenant_id, limit)
        return {
            "count": len(filings),
            "filings": [
                {
                    "filing_id": f.filing_id,
                    "company_name": f.company_name,
                    "form": f.form.value,
                    "status": f.status.value,
                }
                for f in filings
            ],
        }


def bedrock_tool_specs() -> list[dict[str, Any]]:
    """Return the tool specs in Bedrock ``converse`` toolConfig format."""
    return [
        {
            "toolSpec": {
                "name": name,
                "description": spec["description"],
                "inputSchema": {"json": spec["input_schema"]},
            }
        }
        for name, spec in TOOL_SCHEMAS.items()
    ]

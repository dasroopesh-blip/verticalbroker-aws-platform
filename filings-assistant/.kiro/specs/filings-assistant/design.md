# Design: Filings Assistant

This spec's design is documented in depth in the repository docs:

- **Architecture (HLD/LLD, diagrams):** [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md)
- **Decisions & rationale:** [`docs/DESIGN.md`](../../../docs/DESIGN.md)
- **Infrastructure walkthrough:** [`docs/TERRAFORM_GUIDE.md`](../../../docs/TERRAFORM_GUIDE.md)

## Summary

Three layers over a standard ingestion pipeline:

1. **Search / RAG** — Titan embeddings + OpenSearch hybrid (k-NN + BM25) fused
   with Reciprocal Rank Fusion.
2. **MCP server** — capabilities as Model Context Protocol tools, shared with
   the agent via one `ToolRegistry`.
3. **Agentic AI** — a bounded Claude Sonnet tool-use loop returning cited answers.

## Data flows

- **Write:** SEC EDGAR → Postgres (source of truth, checksum-idempotent) → SQS →
  worker (chunk → Titan embed → OpenSearch index).
- **Read:** question → agent (Claude) → MCP tools → hybrid search → cited answer.

## Key interfaces

- `common/bedrock.py::BedrockClient` — `embed_texts`, `converse` (real + mock).
- `common/storage.py` — `FilingRepository`, `JobQueue` (Postgres/SQS + in-memory).
- `search/opensearch_store.py::VectorStore` — index + query (OpenSearch + in-memory).
- `mcp_server/tools.py::ToolRegistry` — the single source of tool behavior.
- `agent/agent.py::FilingsAgent` — the reasoning loop.

## Local/AWS parity

Config (`FA_RUN_MODE`, `FA_USE_MOCK_BEDROCK`) selects fakes vs real services, so
business logic never branches on environment.
```

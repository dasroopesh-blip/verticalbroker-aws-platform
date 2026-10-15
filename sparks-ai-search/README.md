# SPARKS AI Search — SB-6562

Research & proposal package for adding a natural-language **"Ask SPARKS"** search
experience on top of the existing SPARKS OpenSearch keyword search — **without
changing** the current structured search.

- **Jira:** SB-6562 — *research & identify options to enable prompt searching*
- **Audience:** Vertical Relevance → NARB internal review → FED Lead
- **Cost posture:** research & proposal only — **$0 AWS cost now.** Nothing is
  provisioned; spend begins only after FED Lead approval, starting with a capped Dev pilot.

## The two options

| Option | What it is | Best for |
|---|---|---|
| **Option 1 — Generative AI / RAG** | Retrieve from a curated, read-only copy of SPARKS data; Claude generates a grounded answer with citations | Q&A, summaries, "find similar cases," follow-ups |
| **Option 2 — Agentic Hybrid** | An agent decides which approved tools to call (existing OpenSearch, semantic search, record lookups) and reasons across steps | Complex, multi-step questions |

**Recommendation:** build **Option 1 (RAG)** first as the governable near-term
capability, architected so **Option 2 (Agentic)** is an additive evolution that
reuses the same search content and the existing OpenSearch as a tool.

## What's in this package

### Read these first
| File | Purpose |
|---|---|
| [`PROPOSAL.md`](PROPOSAL.md) | The main proposal (exec summary → options → HLD/LLD summary → recommendation → open questions) |
| [`SPARKS_AI_Search_Deck.pptx`](SPARKS_AI_Search_Deck.pptx) | 17-slide stakeholder deck |
| [`SPARKS_AI_Search_Proposal.docx`](SPARKS_AI_Search_Proposal.docx) / [`.html`](SPARKS_AI_Search_Proposal.html) | The proposal as Word / HTML (generated from `PROPOSAL.md`) |

### Design docs
| File | Purpose |
|---|---|
| [`HLD.md`](HLD.md) | High-Level Design — purpose, baseline, target architecture for both options |
| [`LLD.md`](LLD.md) | Low-Level Design — document schema, extractor, chunking, retrieval contract, evaluation, tool contracts |
| [`PRODUCTION_DESIGN.md`](PRODUCTION_DESIGN.md) | End-to-end production-ready design — locked decisions, API spec, security, SLOs, CI/CD, rollback, go-live runbook |
| [`COST_EFFORT_RESOURCES.md`](COST_EFFORT_RESOURCES.md) | Cost / effort / resources / complexity — the NARB "sell" (resource list, LLM & vectorization decision, token/cost model, phasing, risks) |

### Diagrams (`diagrams/`)
Open `.drawio` files in [app.diagrams.net](https://app.diagrams.net) → File → Open.
The `.md` files render as Mermaid directly on GitHub.

| File | Shows |
|---|---|
| `sparks-er-current-asis.drawio` | ER / data model, **as-is** (reference) |
| `sparks-er-option1-2-proposed.drawio` | ER / data model, **proposed (Option 1 & 2)** — the one to review |
| `current-sparks-search.drawio` | Current indexing + search flow (as-is) |
| `option1-rag.drawio` | Option 1 — Generative AI / RAG |
| `option2-agentic.drawio` | Option 2 — Agentic Hybrid |
| `01-current-state.md` · `02-future-option1-rag.md` · `03-future-option2-agentic.md` | Mermaid versions of the above |

### Infrastructure as Code (`infra/terraform/`)
Modular, well-commented Terraform (Dev env + 6 modules). Resource bodies are
intentionally stubbed so the team can review the **shape and wiring** before any
apply. See [`infra/terraform/README.md`](infra/terraform/README.md).

- `enable_agent = false` → deploys **Option 1 (RAG)** only
- `enable_agent = true`  → also deploys **Option 2 (Agentic)** tools + Bedrock Agent
- **No `apply` until FED approval** (`validate` / `plan` are free).

### Build scripts
| Script | Purpose |
|---|---|
| `build_docx.py` | Regenerate `SPARKS_AI_Search_Proposal.docx` from `PROPOSAL.md` (stdlib only) |
| `build_html.py` | Regenerate `SPARKS_AI_Search_Proposal.html` from `PROPOSAL.md` (stdlib only) |

```bash
# Regenerate the Word / HTML proposal after editing PROPOSAL.md:
python3 build_docx.py
python3 build_html.py
```

## Key design decisions (locked)

- **Vector store:** Amazon OpenSearch Serverless vector collection, **separate** from
  the production `sparks-stage` search domain. **Not** pgvector on the production RDS
  (adds load + extension + change-control risk).
- **Models:** Amazon **Titan Text Embeddings v2** (embeddings) + **Claude** (answers);
  optional Claude Haiku later for cheap classify/follow-ups. Pay-per-token — nothing to host.
- **Reuse:** the AI path reads the same `sparks.open_search_json` outbox documents
  (read-only) and reuses each doc's `uniqueId` as the **citation key**.
- **Auth:** reuse the existing SPARKS Okta Lambda Authorizer for the `/ask` route (not new work).
- **EDMAS:** knowledge-exchange checkpoint, **not a dependency** — SPARKS owns its own AI
  stack (which matches EDMAS's note that it won't host a Vector DB / AI for SPARKS). An
  upcoming EDMAS meeting may let us reuse some EDMAS AI components, which would reduce our build.

## Deliberately deferred

Text-to-SQL agent (injection/governance risk), fine-tuned domain model (cost/retraining),
and GraphRAG / knowledge graph (build cost) — all noted so FED sees they were considered.

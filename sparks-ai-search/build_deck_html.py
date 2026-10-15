#!/usr/bin/env python3
"""
Build SPARKS_AI_Search_Stakeholder_Deck.html — a self-contained, presentable HTML
deck (one <section> per slide). Arrow keys to navigate; Print -> Save as PDF for a
handout. Reuses the same slide content as build_pptx.py (kept in sync manually).
Standard library only.
"""
SLIDES = [
 ("title", "SPARKS AI Search",
  ["Enabling natural-language \u201cAsk SPARKS\u201d \u2014 Options & Recommendation",
   "Jira SB-6562 · Vertical Relevance · NARB \u2192 FED Lead",
   "Research & proposal only \u2014 $0 AWS cost now"]),
 ("Agenda", "Agenda",
  ["Why we\u2019re here \u2014 the ask (SB-6562)",
   "Current SPARKS search \u2014 what it does today",
   "The gap \u2014 what it cannot do",
   "Two options: Option 2 (Generative AI / RAG) & Option 3 (Agentic)",
   "LLM & vectorization decision (pgvector?)",
   "Cost (NO-COST-now), effort & timeline",
   "Production readiness \u2014 security, IaC, SLOs",
   "Recommendation, roadmap, and the ask"]),
 ("Ask", "Why we\u2019re here",
  ["THE REQUEST (SB-6562): research & identify options to enable prompt / natural-language searching in SPARKS.",
   "Deliver an ER diagram, research content, and a proposal \u2014 reviewed internally (NARB) before FED.",
   "HARD CONSTRAINT: Bedrock is available in our account, but ZERO cost until the FED Lead approves AI-tool use in Dev.",
   "This deck is the proposal. Nothing is deployed; all costs are forward estimates."]),
 ("Current", "Current state \u2014 SPARKS search today",
  ["Builders write denormalized documents to the open_search_json outbox.",
   "A scheduled pipeline (EventBridge \u2192 Lambda \u2192 SQS \u2192 Lambda) indexes them into Amazon OpenSearch.",
   "Users search via pills / filters / keyword over 8 indexes (vehicle, equipment, investigations, legacy).",
   "STRENGTH: excellent at exact, structured lookups.",
   "Every document already carries a uniqueId (e.g. legacy_equipment:12251) \u2014 a ready-made citation key."]),
 ("Gap", "The gap \u2014 what today\u2019s search cannot do",
  ["Answer natural-language questions",
   "Semantic similarity \u2014 \u201cfind failures like this one\u201d",
   "Summarize or reason across multiple records",
   "Support follow-up questions in context",
   "Return grounded answers with citations",
   "Keyword search matches terms; understanding meaning requires embeddings + an LLM."]),
 ("Principles", "Guiding principles",
  ["Don\u2019t disrupt production search \u2014 existing OpenSearch pipeline untouched.",
   "One experience, not two searches \u2014 add a chat box; route exact vs. semantic behind the scenes.",
   "Reuse what exists \u2014 same outbox documents; reuse uniqueId as citation key.",
   "Governable & grounded \u2014 read-only, least-privilege, guardrails, cited answers.",
   "Evolvable \u2014 build RAG first; Agentic is an additive step."]),
 ("Option 2", "Option 2 \u2014 Generative AI / RAG",
  ["Ask SPARKS chat box \u2192 retrieve relevant SPARKS data \u2192 Claude generates a grounded answer with citations.",
   "Read-only extractor \u2192 curated S3 corpus \u2192 Bedrock Knowledge Base (embed) \u2192 vector store \u2192 Claude.",
   "Exact/filter still uses existing OpenSearch; semantic uses RAG.",
   "Best for Q&A, summaries, similar cases, follow-ups. Our near-term recommendation."]),
 ("Option 3", "Option 3 \u2014 Agentic Hybrid",
  ["Same chat box, but an agent decides which approved tools to call and reasons across steps.",
   "Tools (read-only, no raw SQL): openSearchSearch() (existing index), semanticSearch() (vector corpus),",
   "getInvestigation() / getVehicle() / getEquipment() record lookups.",
   "Best for complex, multi-step questions.",
   "An evolution of Option 2 \u2014 same corpus, same citations, existing OpenSearch reused."]),
 ("Compare", "Options compared",
  ["Option 2 (RAG): retrieve \u2192 generate · lower complexity · best for Q&A/summaries · BUILD FIRST.",
   "Option 3 (Agentic): plan \u2192 call tools \u2192 generate · higher complexity · best for multi-step · ADDITIVE EVOLUTION.",
   "Both: same \u201cAsk SPARKS\u201d chat box; existing structured search unchanged."]),
 ("Deferred", "What we deliberately deferred",
  ["Text-to-SQL agent \u2014 injection / governance risk on production PostgreSQL.",
   "Fine-tuned domain model \u2014 cost, data handling, retraining burden.",
   "GraphRAG / knowledge graph \u2014 high build cost; revisit for cross-failure pattern mining.",
   "Shown for rigor \u2014 we considered and ruled these out for now."]),
 ("LLM/Vector", "LLM & vectorization \u2014 the key technical decision",
  ["LLM: Claude on Amazon Bedrock (house standard, pay-per-token, strong grounding).",
   "Vectorization NEEDED: semantic search requires embeddings (Amazon Titan) + a vector store.",
   "pgvector? NO (not v1): use an OpenSearch vector index \u2014 SPARKS already runs OpenSearch; hybrid keyword+vector.",
   "pgvector would add vector load + an extension + change-control risk to the PRODUCTION database."]),
 ("Cost", "Cost \u2014 and our NO-COST-now posture",
  ["TODAY: $0 in AWS. Nothing provisioned. Research + proposal only.",
   "After approval (Dev pilot, estimates): one-time embedding ~tens of dollars; per query ~cents (Opt 2), a few\u00d7 for Opt 3.",
   "Monthly Dev pilot: ~low tens to low hundreds of dollars + small vector capacity.",
   "Levers: re-embed only changed docs; cap top_k/context; Haiku for classify / Sonnet for answers; AWS Budgets hard cap.",
   "Final dollars pending: doc counts per index + current Bedrock Dev rates."]),
 ("Effort", "Effort & timeline (Dev pilot)",
  ["Option 2 (RAG): extractor \u2192 S3, vector index + KB, Ask API + chat box, evaluation \u2014 ~3\u20135 weeks.",
   "Option 3 (Agentic, additive): agent + tools + guardrails \u2014 +2\u20134 weeks.",
   "One engineer + part-time solution architect. Estimates, not commitments."]),
 ("Prod", "Production-ready \u2014 SPARKS owns the full stack",
  ["Locked design: Claude + Titan on Bedrock; OpenSearch Serverless vector collection (separate from prod search).",
   "Security: private VPC, least-privilege IAM, KMS, Bedrock Guardrails, CloudTrail audit, citations.",
   "Operability: CloudWatch dashboards, SLOs (p95 latency, freshness \u2264 20 min), AWS Budgets hard cap.",
   "IaC: modular Terraform \u2014 one toggle switches Option 2 \u2194 Option 3; nothing applies until approved.",
   "Rollback: feature-flag kill switch; AI layer is derived & read-only \u2014 zero data-loss risk. No EDMAS dependency."]),
 ("Reco", "Recommendation & roadmap",
  ["Build Option 2 (RAG) first \u2014 governable near-term value \u2014 architected so Option 3 is additive.",
   "Phase 0 Foundations: approvals + provision Dev (IaC).",
   "Phase 1 RAG MVP: Ask SPARKS chat box with citations (capped Dev).",
   "Phase 2 Enrich + evaluate: richer corpus + golden-set gate.",
   "Phase 3 Agentic: agent + tools for multi-step questions."]),
 ("Ask/Next", "The ask \u2014 next steps",
  ["FROM FED LEAD: approve Bedrock use in Dev (unlocks the capped pilot).",
   "Agree evaluation thresholds + monthly Dev cost cap.",
   "WE\u2019LL CONFIRM: doc counts per index + Bedrock Dev rates; Okta\u2192IAM mapping (SB-6561); FE chat-box contract.",
   "THEN: provision Dev via Terraform \u2192 backfill \u2192 evaluate with SMEs \u2192 pilot \u2192 decide on Prod / Option 3."]),
]

def esc(s):
    return s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Calibri,'Segoe UI',Arial,sans-serif;background:#333;color:#222}
.slide{width:100vw;height:100vh;display:none;flex-direction:column;background:#fff;padding:0}
.slide.active{display:flex}
.bar{background:#1F3864;color:#fff;padding:28px 48px}
.bar h1{font-size:30px}
.title-slide{justify-content:center;align-items:flex-start;padding:0}
.title-slide .band{background:#1F3864;color:#fff;width:100%;padding:60px 64px}
.title-slide h1{font-size:52px;margin-bottom:14px}
.title-slide .sub{font-size:22px;color:#DCE6F2;margin:4px 0}
.body{flex:1;padding:36px 56px;font-size:22px;line-height:1.55}
.body ul{list-style:none}
.body li{margin:14px 0;padding-left:30px;position:relative}
.body li:before{content:'\\25B8';color:#2E74B5;position:absolute;left:0}
.counter{position:fixed;bottom:14px;right:22px;color:#aaa;font-size:14px}
.hint{position:fixed;bottom:14px;left:22px;color:#aaa;font-size:13px}
@media print{
  .slide{display:flex!important;page-break-after:always;height:7.3in;width:13in}
  .counter,.hint{display:none}
  body{background:#fff}
}
"""

JS = """
let i=0;const s=[...document.querySelectorAll('.slide')];
function show(n){s.forEach(x=>x.classList.remove('active'));i=Math.max(0,Math.min(n,s.length-1));s[i].classList.add('active');document.getElementById('c').textContent=(i+1)+' / '+s.length;}
document.addEventListener('keydown',e=>{if(e.key==='ArrowRight'||e.key===' ')show(i+1);if(e.key==='ArrowLeft')show(i-1);});
document.addEventListener('click',()=>show(i+1));
show(0);
"""

def render():
    out=[]
    for idx,(name,title,items) in enumerate(SLIDES):
        if name=="title":
            lis="".join(f"<div class='sub'>{esc(x)}</div>" for x in items)
            out.append(f"<section class='slide title-slide'><div class='band'><h1>{esc(title)}</h1>{lis}</div></section>")
        else:
            lis="".join(f"<li>{esc(x)}</li>" for x in items)
            out.append(f"<section class='slide'><div class='bar'><h1>{esc(title)}</h1></div><div class='body'><ul>{lis}</ul></div></section>")
    html=(f"<!doctype html><html lang='en'><head><meta charset='utf-8'>"
          f"<meta name='viewport' content='width=device-width,initial-scale=1'>"
          f"<title>SPARKS AI Search \u2014 Stakeholder Deck</title><style>{CSS}</style></head><body>"
          f"{''.join(out)}"
          f"<div class='counter' id='c'></div><div class='hint'>\u2190/\u2192 or click to navigate \u00b7 Print \u2192 Save as PDF</div>"
          f"<script>{JS}</script></body></html>")
    with open("SPARKS_AI_Search_Stakeholder_Deck.html","w",encoding="utf-8") as f:
        f.write(html)
    print(f"Wrote SPARKS_AI_Search_Stakeholder_Deck.html ({len(SLIDES)} slides)")

if __name__=="__main__":
    render()

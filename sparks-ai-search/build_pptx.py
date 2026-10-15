#!/usr/bin/env python3
"""
Build SPARKS_AI_Search_Stakeholder_Deck.pptx by using a REAL PowerPoint file
(sample.pptx, produced by PowerPoint/python-pptx) as the structural template.

Why this works where hand-rolling failed:
  - We keep EVERY structural part from the known-good file byte-for-byte
    (slideMaster, 12 slideLayouts, theme, presProps, viewProps, tableStyles,
     notesMaster, docProps, _rels) so PowerPoint accepts the package.
  - We only REPLACE the slide text parts (ppt/slides/slideN.xml) with our content,
    reusing the sample's own slide1 (title) and slide2 (title+bullets) shapes.
  - We rewrite presentation.xml, its .rels, and [Content_Types].xml so they list
    exactly our N slides.

Run:  python3 build_pptx.py
Requires: sample.pptx present (clone from the verticalbroker repo). Path is auto-detected.
"""
import os
import re
import shutil
import zipfile

OUT = "SPARKS_AI_Search_Stakeholder_Deck.pptx"

# ---- locate the template ----
CANDIDATES = [
    "sample.pptx",
    "../verticalbroker-aws-platform/sample.pptx",
    "/projects/sandbox/verticalbroker-aws-platform/sample.pptx",
]
TEMPLATE = next((p for p in CANDIDATES if os.path.exists(p)), None)
if not TEMPLATE:
    raise SystemExit("sample.pptx not found. Clone dasroopesh-blip/verticalbroker-aws-platform first.")

def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))

# ---- slide XML builders that MIRROR the sample's shapes exactly ----
A = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
R = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
P = 'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
HEAD = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<p:sld {A} {R} {P}>'
GRP = ('<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
       '</p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
       '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>')
TAIL = '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'

def _p(text):
    return f'<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>{esc(text)}</a:t></a:r></a:p>'

def title_slide_xml(title, sub_lines):
    # mirrors sample slide1: ctrTitle + subTitle, layout1
    subparas = "".join(_p(x) for x in sub_lines)
    return (HEAD + GRP +
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr>'
        '<a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="ctrTitle"/></p:nvPr>'
        '</p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        f'{_p(title)}</p:txBody></p:sp>'
        '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Subtitle 2"/><p:cNvSpPr>'
        '<a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="subTitle" idx="1"/></p:nvPr>'
        '</p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        f'{subparas}</p:txBody></p:sp>' + TAIL)

def content_slide_xml(title, bullets):
    # mirrors sample slide2: title + content placeholder (idx 1), layout2
    body = "".join(_p(b) for b in bullets)
    return (HEAD + GRP +
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr>'
        '<a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr>'
        '</p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        f'{_p(title)}</p:txBody></p:sp>'
        '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Content Placeholder 2"/><p:cNvSpPr>'
        '<a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr>'
        '</p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        f'{body}</p:txBody></p:sp>' + TAIL)

# ======================= DECK CONTENT =======================
# ("title", heading, [sub lines])  OR  ("content", heading, [bullets])
DECK = [
 ("title", "SPARKS AI Search", [
    'Enabling natural-language "Ask SPARKS" - Options & Recommendation',
    "Jira SB-6562  -  Vertical Relevance  -  NARB review then FED Lead",
    "Research & proposal only - $0 AWS cost now. Nothing deployed.",
 ]),
 ("content", "Agenda", [
    "Why we're here - the ask (SB-6562)",
    "Current SPARKS search - what it does today",
    "The gap - what it cannot do",
    "Two options: Option 2 (Generative AI / RAG) and Option 3 (Agentic)",
    "LLM & vectorization decision (pgvector?)",
    "Cost (NO-COST-now), effort & timeline",
    "Production readiness - security, IaC, SLOs",
    "Recommendation, roadmap, and the ask",
 ]),
 ("content", "Why we're here", [
    "The request (SB-6562): research & identify options to enable prompt / natural-language searching in SPARKS.",
    "Deliver an ER diagram, research content, and a proposal - reviewed by NARB before FED.",
    "Hard constraint: Bedrock is available in our account, but ZERO cost until the FED Lead approves AI use in Dev.",
    "This deck is the proposal. Nothing is deployed; all costs are forward estimates.",
 ]),
 ("content", "Current state - SPARKS search today", [
    "PostgreSQL builders write denormalized documents to the open_search_json outbox.",
    "A scheduled pipeline (EventBridge, Lambda, SQS, Lambda) indexes them into Amazon OpenSearch.",
    "Users search via pills / filters / keyword over 8 indexes (vehicle, equipment, investigations, legacy).",
    "Strength: excellent at exact, structured lookups.",
    "Every document already carries a uniqueId (e.g. legacy_equipment:12251) - a ready-made citation key.",
 ]),
 ("content", "The gap - what today's search cannot do", [
    "Answer natural-language questions",
    "Semantic similarity - 'find failures like this one'",
    "Summarize or reason across multiple records",
    "Support follow-up questions in context",
    "Return grounded answers with citations",
    "Keyword search matches terms; understanding meaning requires embeddings + an LLM.",
 ]),
 ("content", "Guiding principles", [
    "Don't disrupt production search - the existing OpenSearch pipeline is untouched.",
    "One experience, not two searches - add a chat box; route exact vs. semantic behind the scenes.",
    "Reuse what exists - same outbox documents; reuse uniqueId as the citation key.",
    "Governable & grounded - read-only access, least-privilege, guardrails, cited answers.",
    "Evolvable - build RAG first; make Agentic an additive step.",
 ]),
 ("content", "Option 2 - Generative AI / RAG", [
    "Ask SPARKS chat box: retrieve relevant SPARKS data, then Claude generates a grounded answer with citations.",
    "How: read-only extractor -> curated S3 corpus -> Bedrock Knowledge Base (embed) -> vector store -> Claude.",
    "Exact/filter still uses existing OpenSearch; semantic uses RAG.",
    "Best for: Q&A, summaries, similar cases, follow-ups. Simpler, easy to govern - near-term recommendation.",
 ]),
 ("content", "Option 3 - Agentic Hybrid", [
    "Same chat box, but an agent decides which approved tools to call and reasons across multiple steps.",
    "Tool: openSearchSearch() - the EXISTING index, reused as a tool.",
    "Tool: semanticSearch() - the Option 2 vector corpus.",
    "Tool: getInvestigation() / getVehicle() / getEquipment() - read-only record lookups (no raw SQL).",
    "Best for complex, multi-step questions. An evolution of Option 2 - same corpus, same citations.",
 ]),
 ("content", "Options compared", [
    "Interface: both use the same Ask SPARKS chat box.",
    "Option 2 (RAG): retrieve -> generate | lower complexity | best for Q&A, summaries, similar cases | BUILD FIRST.",
    "Option 3 (Agentic): plan -> call tools -> generate | higher complexity | best for multi-step | ADDITIVE EVOLUTION.",
    "Both reuse the existing OpenSearch; the current structured search is unchanged.",
 ]),
 ("content", "What we deliberately deferred", [
    "Text-to-SQL agent - injection / governance risk on production PostgreSQL.",
    "Fine-tuned domain model - cost, data handling, retraining burden.",
    "GraphRAG / knowledge graph - high build cost; revisit for cross-failure pattern mining.",
    "Shown for rigor - we considered and ruled these out for now.",
 ]),
 ("content", "LLM & vectorization - the key technical decision", [
    "LLM: Claude on Amazon Bedrock (house standard, pay-per-token, strong grounding).",
    "Vectorization NEEDED: semantic search requires embeddings (Amazon Titan) + a vector store.",
    "pgvector? NO (not v1): use an OpenSearch vector index - SPARKS already runs OpenSearch; hybrid keyword+vector.",
    "pgvector would add vector load + an extension + change-control risk to the PRODUCTION database.",
 ]),
 ("content", "Cost - and our NO-COST-now posture", [
    "Today: $0 in AWS. Nothing provisioned. Research + proposal only.",
    "After approval (Dev pilot, estimates): one-time embedding ~tens of dollars (one time).",
    "Per query: cents (Option 2); a few times that for Option 3 (more LLM turns).",
    "Monthly Dev pilot: low tens to low hundreds of dollars + small vector capacity.",
    "Levers: re-embed only changed docs; cap top_k & context; Haiku for classify / Sonnet for answers; AWS Budgets hard cap.",
 ]),
 ("content", "Effort & timeline (Dev pilot)", [
    "Option 2 (RAG): extractor -> S3, vector index + KB, Ask API + chat box, evaluation. Rough order ~3-5 weeks.",
    "Option 3 (Agentic, additive): agent + tools + guardrails. +2-4 weeks.",
    "One engineer + part-time solution architect. Estimates, not commitments.",
 ]),
 ("content", "Production-ready - SPARKS owns the full stack", [
    "Locked design: Claude + Titan on Bedrock; OpenSearch Serverless vector collection (separate from prod search).",
    "Security: private VPC, least-privilege IAM, KMS, Bedrock Guardrails, CloudTrail audit, citations.",
    "Operability: CloudWatch dashboards, SLOs (p95 latency, freshness <= 20 min), AWS Budgets hard cap.",
    "IaC: modular Terraform - one toggle switches Option 2 and Option 3; nothing applies until approved.",
    "Rollback: feature-flag kill switch; AI layer is derived & read-only - zero data-loss risk. No EDMAS dependency.",
 ]),
 ("content", "Recommendation & roadmap", [
    "Recommendation: build Option 2 (RAG) first - governable near-term value - so Option 3 (Agentic) is additive.",
    "Phase 0 Foundations: approvals + provision Dev via IaC (gated).",
    "Phase 1 RAG MVP: Ask SPARKS chat box with citations (capped Dev).",
    "Phase 2 Enrich + evaluate: richer corpus + golden-set gate (small).",
    "Phase 3 Agentic: agent + tools for multi-step questions (higher).",
 ]),
 ("content", "The ask - next steps", [
    "From the FED Lead: approve Bedrock use in the Dev environment (unlocks the capped pilot).",
    "Agree evaluation thresholds and the monthly Dev cost cap.",
    "We'll confirm: document counts per index + current Bedrock Dev rates.",
    "We'll confirm: Okta -> IAM identity mapping (SB-6561) and the FE chat-box contract.",
    "Then: provision Dev via Terraform -> backfill -> evaluate with SMEs -> pilot -> decide on Prod / Option 3.",
 ]),
]

def main():
    n = len(DECK)
    zin = zipfile.ZipFile(TEMPLATE, "r")
    names = zin.namelist()

    # how many slides does the template have? (to know which parts to drop/keep)
    tmpl_slides = sorted(
        int(re.search(r"slide(\d+)\.xml$", x).group(1))
        for x in names if re.match(r"ppt/slides/slide\d+\.xml$", x))
    tmpl_count = len(tmpl_slides)

    # Build the new slide XML + per-slide rels (title->layout1, content->layout2)
    new_slides = {}
    new_slide_rels = {}
    for i, (kind, head, items) in enumerate(DECK, start=1):
        if kind == "title":
            new_slides[i] = title_slide_xml(head, items)
            layout = "slideLayout1.xml"
        else:
            new_slides[i] = content_slide_xml(head, items)
            layout = "slideLayout2.xml"
        new_slide_rels[i] = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/{layout}"/>'
            '</Relationships>')

    # Rewrite presentation.xml: keep everything, replace the <p:sldIdLst> with our N slides.
    pres = zin.read("ppt/presentation.xml").decode("utf-8")
    sldids = "".join(f'<p:sldId id="{256+i}" r:id="rIdSL{i}"/>' for i in range(1, n+1))
    pres = re.sub(r"<p:sldIdLst>.*?</p:sldIdLst>",
                  f"<p:sldIdLst>{sldids}</p:sldIdLst>", pres, flags=re.S)

    # Rewrite presentation rels: keep non-slide rels (master, notesMaster, theme,
    # presProps, viewProps, tableStyles), replace slide rels with our N using rIdSL ids.
    pres_rels = zin.read("ppt/_rels/presentation.xml.rels").decode("utf-8")
    # drop existing slide relationships
    pres_rels = re.sub(
        r'<Relationship[^>]*Type="[^"]*/slide"[^>]*/>', "", pres_rels)
    slide_rel_xml = "".join(
        f'<Relationship Id="rIdSL{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide{i}.xml"/>'
        for i in range(1, n+1))
    pres_rels = pres_rels.replace("</Relationships>", slide_rel_xml + "</Relationships>")

    # Rewrite [Content_Types].xml: ensure exactly our N slide overrides are present.
    ct = zin.read("[Content_Types].xml").decode("utf-8")
    ct = re.sub(r'<Override PartName="/ppt/slides/slide\d+\.xml"[^>]*/>', "", ct)
    slide_ovr = "".join(
        f'<Override PartName="/ppt/slides/slide{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        for i in range(1, n+1))
    ct = ct.replace("</Types>", slide_ovr + "</Types>")

    # Parts to SKIP copying from the template (we regenerate these):
    skip = {"ppt/presentation.xml", "ppt/_rels/presentation.xml.rels", "[Content_Types].xml"}
    for s in tmpl_slides:
        skip.add(f"ppt/slides/slide{s}.xml")
        skip.add(f"ppt/slides/_rels/slide{s}.xml.rels")

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zout:
        # 1) copy every template part we are keeping, preserving compression type
        for item in zin.infolist():
            if item.filename in skip:
                continue
            data = zin.read(item.filename)
            zout.writestr(item, data)  # preserves STORED/DEFLATED like the original
        # 2) write our regenerated top-level parts
        zout.writestr("[Content_Types].xml", ct)
        zout.writestr("ppt/presentation.xml", pres)
        zout.writestr("ppt/_rels/presentation.xml.rels", pres_rels)
        # 3) write our slides + their rels
        for i in range(1, n+1):
            zout.writestr(f"ppt/slides/slide{i}.xml", new_slides[i])
            zout.writestr(f"ppt/slides/_rels/slide{i}.xml.rels", new_slide_rels[i])

    zin.close()
    print(f"Wrote {OUT} from template {TEMPLATE}: {n} slides "
          f"(template had {tmpl_count}).")

if __name__ == "__main__":
    main()

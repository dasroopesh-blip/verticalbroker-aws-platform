#!/usr/bin/env python3
"""
Bundle of deck edits (one push):
  - slide 4 : fix broken uniqueId bullet (3 fragments -> 1 clean paragraph)
  - slide 7 : "curated S3 object" -> "curated S3 search content"; keep single How line
              (two-phase wording), models stay implicit
  - slide 8 : "Option 1 vector corpus" -> "Option 1 vector index"; "same corpus" -> "same content"
  - slide 14: "Terraform or Jenkins- one" -> "Terraform (deployed via CI/CD, e.g. Jenkins) - one"
  - slide 15: "richer corpus" -> "richer search content"
  - NEW slide inserted after slide 14: "Resources - old vs. new" (bulleted),
    stating "2 Bedrock models (Titan + Claude); optional 3rd (Claude Haiku) for cost"

Keeps all other parts byte-for-byte. Renumbers slides after insertion and updates
presentation.xml, its rels, and [Content_Types].xml so the package stays valid.
"""
import re
import zipfile

SRC = "SPARKS_AI_Search_Deck.pptx"
OUT = "SPARKS_AI_Search_Deck.pptx"

# ---------- simple in-place text replacements ----------
TEXT_SUBS = {
    "ppt/slides/slide7.xml": [
        ("How: read-only extractor -&gt; curated S3 object -&gt; Bedrock Knowledge Base (embed) -&gt; vector store -&gt; Claude.",
         "Prepare (scheduled): read-only extractor -&gt; curated S3 search content -&gt; Bedrock Knowledge Base embeds -&gt; vector index."),
        ("Exact/filter still uses existing OpenSearch; semantic uses RAG.",
         "Answer (live): user question -&gt; retrieve top matches from vector index -&gt; Claude writes a grounded answer. Exact/filter still uses existing OpenSearch."),
    ],
    "ppt/slides/slide8.xml": [
        ("Tool: semanticSearch() - the Option 1 vector corpus.",
         "Tool: semanticSearch() - the Option 1 vector index."),
        ("Best for complex, multi-step questions. An evolution of Option 1 - same corpus, same citations.",
         "Best for complex, multi-step questions. An evolution of Option 1 - same content, same citations."),
    ],
    "ppt/slides/slide14.xml": [
        ("IaC: modular Terraform or Jenkins- one toggle switches Option 1 and Option 2; nothing applies until approved.",
         "IaC: modular Terraform (deployed via CI/CD, e.g. Jenkins) - one toggle switches Option 1 and Option 2; nothing applies until approved."),
    ],
    "ppt/slides/slide15.xml": [
        ("Phase 2 Enrich + evaluate: richer corpus + golden-set gate (small).",
         "Phase 2 Enrich + evaluate: richer search content + golden-set gate (small)."),
    ],
}

# ---------- slide 4: rebuild the content placeholder paragraphs cleanly ----------
SLIDE4_BULLETS = [
    "PostgreSQL builders write denormalized documents to the open_search_json outbox.",
    "A scheduled pipeline (EventBridge, Lambda, SQS, Lambda) indexes them into Amazon OpenSearch.",
    "Users search via pills / filters / keyword over 8 indexes (vehicle, equipment, investigations, legacy).",
    "Strength: excellent at exact, structured lookups.",
    "Every document already carries a uniqueId (e.g. legacy_equipment:12251) - a ready-made citation key.",
]

# ---------- NEW "Resources" slide content ----------
RES_TITLE = "Resources - old vs. new"
RES_BULLETS = [
    "EXISTING (reused, untouched): RDS/PostgreSQL + builders; open_search_json outbox; 2 indexer Lambdas; SQS FIFO; OpenSearch sparks-stage (8 indexes); API Gateway + Okta Lambda Authorizer.",
    "NEW - Option 1 (RAG): 1 S3 bucket (8 domain folders); 2 Lambdas (extractor, Ask-SPARKS); 1 Bedrock Knowledge Base; 1 vector index (OpenSearch Serverless); 1 Guardrail; /ask API route (existing authorizer).",
    "Bedrock models: 2 (Amazon Titan = embeddings, Claude = answers). Optional 3rd (Claude Haiku) later for cost. Models are invoked pay-per-token - nothing to host.",
    "NEW - Option 2 (Agentic, additive): 1 Bedrock Agent; 3 tool Lambdas (semanticSearch, openSearchSearch, getInvestigation/Vehicle/Equipment); 3 Action Groups; 3 read-only RDS views. Reuses Option 1's S3, KB, vector index, Claude.",
    "Supporting: KMS key, SQS DLQ, SSM watermark, 1 refresh schedule, CloudWatch dashboard + AWS Budget cap.",
]

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def paras(lines):
    return "".join(
        f'<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>{esc(x)}</a:t></a:r></a:p>'
        for x in lines)

def content_slide_xml(title, bullets):
    A='xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
    R='xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
    P='xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<p:sld {A} {R} {P}>'
        '<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
        '</p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
        '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
        '<p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        f'<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>{esc(title)}</a:t></a:r></a:p></p:txBody></p:sp>'
        '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Content Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
        '<p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        f'{paras(bullets)}</p:txBody></p:sp>'
        '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>')

def rebuild_slide4(xml):
    # replace the entire <p:txBody> of the content placeholder (the 2nd sp) body paragraphs.
    # Strategy: the content placeholder has ph idx="1"; replace its paragraphs.
    new_body = paras(SLIDE4_BULLETS)
    # Find the content placeholder sp (contains '<p:ph idx="1"/>') and swap its paragraphs.
    # We locate its <a:lstStyle/> ... up to </p:txBody> and replace inner paragraphs.
    # Simpler + robust: replace everything from the first '<a:p>' AFTER ph idx="1" to the
    # matching '</p:txBody>' of that shape.
    idx = xml.find('<p:ph idx="1"/>')
    if idx == -1:
        raise SystemExit("slide4: content placeholder not found")
    tb_start = xml.find('<p:txBody>', idx)
    tb_end = xml.find('</p:txBody>', tb_start)
    before = xml[:tb_start]
    after = xml[tb_end+len('</p:txBody>'):]
    new_tb = f'<p:txBody><a:bodyPr/><a:lstStyle/>{new_body}</p:txBody>'
    return before + new_tb + after

def main():
    zin = zipfile.ZipFile(SRC, "r")
    infos = zin.infolist()
    parts = {i.filename: zin.read(i.filename) for i in infos}
    zin.close()

    # 1) text subs
    for part, subs in TEXT_SUBS.items():
        xml = parts[part].decode("utf-8")
        for old, new in subs:
            if old not in xml:
                raise SystemExit(f"NOT FOUND in {part}:\n  {old}")
            xml = xml.replace(old, new)
        parts[part] = xml.encode("utf-8")

    # 2) rebuild slide 4
    parts["ppt/slides/slide4.xml"] = rebuild_slide4(
        parts["ppt/slides/slide4.xml"].decode("utf-8")).encode("utf-8")

    # 3) figure out current slide count
    sl_nums = sorted(int(re.search(r'slide(\d+)\.xml$', n).group(1))
                     for n in parts if re.match(r'ppt/slides/slide\d+\.xml$', n))
    n = len(sl_nums)                      # 16
    insert_after = 14                     # new Resources slide becomes slide 15
    new_total = n + 1                     # 17

    # 4) shift slides 15,16 -> 16,17 (rename their parts + rels). Do high->low to avoid clobber.
    def rename(oldnum, newnum):
        for base in (f"ppt/slides/slide{oldnum}.xml",
                     f"ppt/slides/_rels/slide{oldnum}.xml.rels"):
            if base in parts:
                newname = base.replace(f"slide{oldnum}.", f"slide{newnum}.")
                parts[newname] = parts.pop(base)
    for old in range(n, insert_after, -1):      # 16, 15
        rename(old, old+1)

    # 5) create the new Resources slide at position 15 (content layout = slideLayout2)
    parts[f"ppt/slides/slide{insert_after+1}.xml"] = content_slide_xml(RES_TITLE, RES_BULLETS).encode("utf-8")
    parts[f"ppt/slides/_rels/slide{insert_after+1}.xml.rels"] = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout2.xml"/>'
        '</Relationships>').encode("utf-8")

    # 6) rewrite presentation.xml sldIdLst to list 1..new_total in order via rIdSL ids
    pres = parts["ppt/presentation.xml"].decode("utf-8")
    sldids = "".join(f'<p:sldId id="{256+i}" r:id="rIdSL{i}"/>' for i in range(1, new_total+1))
    pres = re.sub(r"<p:sldIdLst>.*?</p:sldIdLst>",
                  f"<p:sldIdLst>{sldids}</p:sldIdLst>", pres, flags=re.S)
    parts["ppt/presentation.xml"] = pres.encode("utf-8")

    # 7) rewrite presentation rels: keep non-slide rels, set slide rels rIdSL1..N
    pr = parts["ppt/_rels/presentation.xml.rels"].decode("utf-8")
    pr = re.sub(r'<Relationship[^>]*Type="[^"]*/slide"[^>]*/>', "", pr)
    slide_rel = "".join(
        f'<Relationship Id="rIdSL{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide{i}.xml"/>'
        for i in range(1, new_total+1))
    pr = pr.replace("</Relationships>", slide_rel + "</Relationships>")
    parts["ppt/_rels/presentation.xml.rels"] = pr.encode("utf-8")

    # 8) [Content_Types].xml: ensure overrides for slides 1..new_total
    ct = parts["[Content_Types].xml"].decode("utf-8")
    ct = re.sub(r'<Override PartName="/ppt/slides/slide\d+\.xml"[^>]*/>', "", ct)
    ov = "".join(
        f'<Override PartName="/ppt/slides/slide{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        for i in range(1, new_total+1))
    ct = ct.replace("</Types>", ov + "</Types>")
    parts["[Content_Types].xml"] = ct.encode("utf-8")

    # 9) write out, preserving original compression where we can
    comp = {i.filename: i.compress_type for i in infos}
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in parts.items():
            z.writestr(name, data, compress_type=comp.get(name, zipfile.ZIP_DEFLATED))
    print(f"Done. Slides now: {new_total} (added 'Resources' as slide {insert_after+1}).")

if __name__ == "__main__":
    main()

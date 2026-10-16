#!/usr/bin/env python3
"""
Build SPARKS_AI_Search_Proposal.docx from scratch using only the standard library.
A .docx is a ZIP of OOXML parts; we emit a minimal, valid WordprocessingML document.

Supports a small Markdown-ish subset tailored to PROPOSAL.md:
  # / ## / ###        -> headings
  - bullet            -> bullet list
  1. ordered          -> numbered list
  | a | b |           -> table (consecutive rows; separator row ignored)
  **bold** and `code` -> inline runs
  > quote             -> indented italic
  ---                 -> horizontal rule (rendered as a thin bottom border paragraph)
  blank line          -> paragraph break
"""
import html
import re
import zipfile

SRC = "PROPOSAL.md"
OUT = "SPARKS_AI_Search_Proposal.docx"

# ---------- XML escaping ----------
def esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

# ---------- inline runs: **bold**, `code`, plain ----------
def runs(text: str) -> str:
    # tokenize on **bold** and `code`
    parts = re.split(r"(\*\*.+?\*\*|`[^`]+`)", text)
    out = []
    for p in parts:
        if not p:
            continue
        if p.startswith("**") and p.endswith("**"):
            inner = esc(p[2:-2])
            out.append(f'<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">{inner}</w:t></w:r>')
        elif p.startswith("`") and p.endswith("`"):
            inner = esc(p[1:-1])
            out.append(f'<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>'
                       f'<w:color w:val="A6261D"/></w:rPr>'
                       f'<w:t xml:space="preserve">{inner}</w:t></w:r>')
        else:
            out.append(f'<w:r><w:t xml:space="preserve">{esc(p)}</w:t></w:r>')
    return "".join(out) or '<w:r><w:t></w:t></w:r>'

def para(text="", style=None, bullet=False, number=False, quote=False, hr=False):
    ppr = []
    if style:
        ppr.append(f'<w:pStyle w:val="{style}"/>')
    if bullet:
        ppr.append('<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>')
    if number:
        ppr.append('<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>')
    if quote:
        ppr.append('<w:ind w:left="360"/>')
    if hr:
        ppr.append('<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="BBBBBB"/></w:pBdr>')
    ppr_xml = f"<w:pPr>{''.join(ppr)}</w:pPr>" if ppr else ""
    if quote:
        body = f'<w:r><w:rPr><w:i/><w:color w:val="555555"/></w:rPr><w:t xml:space="preserve">{esc(text)}</w:t></w:r>'
    elif hr:
        body = ""
    else:
        body = runs(text)
    return f"<w:p>{ppr_xml}{body}</w:p>"

FLOW_FILLS = ["DAE8FC", "FFE6CC", "E1D5E7", "D5E8D4", "DAE8FC"]
FLOW_EDGES = ["6C8EBF", "D79B00", "9673A6", "82B366", "6C8EBF"]

def flow_diagram(title, steps, notes):
    """Render a horizontal flow as a borderless table: box | ▶ | box | ▶ | box ..."""
    out = []
    if title:
        out.append('<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="120" w:after="80"/></w:pPr>'
                   f'<w:r><w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="24"/></w:rPr>'
                   f'<w:t xml:space="preserve">{esc(title)}</w:t></w:r></w:p>')
    # build cells: alternating box and arrow
    ncols = len(steps) * 2 - 1 if steps else 0
    grid = '<w:tblGrid>' + ''.join('<w:gridCol/>' for _ in range(ncols)) + '</w:tblGrid>'
    tblpr = ('<w:tblPr><w:tblW w:w="5000" w:type="pct"/>'
             '<w:tblLayout w:type="fixed"/><w:jc w:val="center"/></w:tblPr>')
    cells = []
    for idx, (h, body) in enumerate(steps):
        fill = FLOW_FILLS[idx % len(FLOW_FILLS)]
        edge = FLOW_EDGES[idx % len(FLOW_EDGES)]
        bdr = (f'<w:tcBorders>'
               f'<w:top w:val="single" w:sz="12" w:color="{edge}"/>'
               f'<w:left w:val="single" w:sz="12" w:color="{edge}"/>'
               f'<w:bottom w:val="single" w:sz="12" w:color="{edge}"/>'
               f'<w:right w:val="single" w:sz="12" w:color="{edge}"/></w:tcBorders>')
        hpar = ('<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="40"/></w:pPr>'
                f'<w:r><w:rPr><w:b/><w:sz w:val="18"/></w:rPr>'
                f'<w:t xml:space="preserve">{esc(h)}</w:t></w:r></w:p>')
        bpar = ('<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="0"/></w:pPr>'
                f'<w:r><w:rPr><w:sz w:val="15"/></w:rPr>'
                f'<w:t xml:space="preserve">{esc(body)}</w:t></w:r></w:p>')
        cells.append(f'<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/>'
                     f'<w:shd w:val="clear" w:fill="{fill}"/>{bdr}'
                     f'<w:vAlign w:val="center"/></w:tcPr>{hpar}{bpar}</w:tc>')
        if idx < len(steps) - 1:
            cells.append('<w:tc><w:tcPr><w:tcW w:w="300" w:type="dxa"/>'
                         '<w:vAlign w:val="center"/></w:tcPr>'
                         '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
                         '<w:r><w:rPr><w:color w:val="2E74B5"/><w:sz w:val="24"/></w:rPr>'
                         '<w:t>&#9654;</w:t></w:r></w:p></w:tc>')
    out.append(f'<w:tbl>{tblpr}{grid}<w:tr>{"".join(cells)}</w:tr></w:tbl>')
    for n in notes:
        out.append(para(n, bullet=True))
    out.append(para(""))  # spacer
    return "".join(out)

def table(rows):
    # rows: list of list[str]; first row = header
    grid_cols = max(len(r) for r in rows)
    borders = ('<w:tblBorders>'
               '<w:top w:val="single" w:sz="4" w:color="CCCCCC"/>'
               '<w:left w:val="single" w:sz="4" w:color="CCCCCC"/>'
               '<w:bottom w:val="single" w:sz="4" w:color="CCCCCC"/>'
               '<w:right w:val="single" w:sz="4" w:color="CCCCCC"/>'
               '<w:insideH w:val="single" w:sz="4" w:color="CCCCCC"/>'
               '<w:insideV w:val="single" w:sz="4" w:color="CCCCCC"/>'
               '</w:tblBorders>')
    tblpr = (f'<w:tblPr><w:tblStyle w:val="TableGrid"/>'
             f'<w:tblW w:w="5000" w:type="pct"/>{borders}</w:tblPr>')
    grid = '<w:tblGrid>' + ''.join('<w:gridCol/>' for _ in range(grid_cols)) + '</w:tblGrid>'
    body = [tblpr, grid]
    for i, r in enumerate(rows):
        cells = []
        for c in range(grid_cols):
            txt = r[c] if c < len(r) else ""
            shade = '<w:shd w:val="clear" w:fill="EEF2F7"/>' if i == 0 else ''
            run = (f'<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">{esc(txt)}</w:t></w:r>'
                   if i == 0 else runs(txt))
            cells.append(f'<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/>{shade}</w:tcPr>'
                         f'<w:p>{run}</w:p></w:tc>')
        body.append(f'<w:tr>{"".join(cells)}</w:tr>')
    return f'<w:tbl>{"".join(body)}</w:tbl>'

# ---------- parse PROPOSAL.md ----------
def parse(md: str):
    blocks = []
    lines = md.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        s = line.rstrip()

        # ::flow:: ... ::endflow::  -> styled horizontal box diagram
        if s.strip().startswith("::flow::"):
            title = s.strip()[len("::flow::"):].strip()
            i += 1
            steps = []; notes = []; buf = ""
            def _flush(b):
                b = b.strip().rstrip("|").strip()
                if not b: return
                if "::" in b:
                    h, _, body = b.partition("::")
                    steps.append((h.strip(), body.strip()))
                else:
                    steps.append(("", b))
            while i < len(lines) and lines[i].strip() != "::endflow::":
                ln = lines[i].strip()
                if ln.startswith("::note::"):
                    notes.append(ln[len("::note::"):].strip()); i += 1; continue
                buf += " " + ln
                while "||" in buf:
                    part, _, buf = buf.partition("||"); _flush(part)
                i += 1
            _flush(buf)
            i += 1  # skip ::endflow::
            blocks.append(("flow", (title, steps, notes)))
            continue

        # ```mermaid ... ```  -> skip in Word (flow diagram already rendered)
        if s.strip().startswith("```mermaid"):
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                i += 1
            i += 1  # skip closing fence
            continue

        # table: collect consecutive pipe rows
        if s.strip().startswith("|") and s.strip().endswith("|"):
            tbl = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                # skip markdown separator row (---|---)
                if not all(set(c) <= set("-: ") and c for c in cells):
                    tbl.append(cells)
                i += 1
            blocks.append(("table", tbl))
            continue

        if not s.strip():
            i += 1
            continue
        if s.startswith("### "):
            blocks.append(("h3", s[4:]))
        elif s.startswith("## "):
            blocks.append(("h2", s[3:]))
        elif s.startswith("# "):
            blocks.append(("h1", s[2:]))
        elif s.strip() == "---":
            blocks.append(("hr", ""))
        elif s.lstrip().startswith("> "):
            blocks.append(("quote", s.lstrip()[2:]))
        elif re.match(r"^\s*[-*]\s+", s):
            blocks.append(("bullet", re.sub(r"^\s*[-*]\s+", "", s)))
        elif re.match(r"^\s*\d+\.\s+", s):
            blocks.append(("number", re.sub(r"^\s*\d+\.\s+", "", s)))
        else:
            blocks.append(("p", s))
        i += 1
    return blocks

def body_xml(blocks):
    out = []
    style_map = {"h1": "Heading1", "h2": "Heading2", "h3": "Heading3"}
    for kind, val in blocks:
        if kind in style_map:
            # strip leading markdown link anchors / numbering already in text is fine
            out.append(para(val, style=style_map[kind]))
        elif kind == "p":
            out.append(para(val))
        elif kind == "bullet":
            out.append(para(val, bullet=True))
        elif kind == "number":
            out.append(para(val, number=True))
        elif kind == "quote":
            out.append(para(val, quote=True))
        elif kind == "hr":
            out.append(para(hr=True))
        elif kind == "table":
            out.append(table(val))
            out.append(para(""))  # spacer
        elif kind == "flow":
            title, steps, notes = val
            out.append(flow_diagram(title, steps, notes))
    return "".join(out)

# ---------- OOXML part templates ----------
CONTENT_TYPES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
</Types>'''

RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''

DOC_RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
</Relationships>'''

STYLES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="21"/></w:rPr></w:rPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="40"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="2" w:color="2E74B5"/></w:pBdr><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="30"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="60"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="25"/></w:rPr></w:style>
<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:color="CCCCCC"/><w:left w:val="single" w:sz="4" w:color="CCCCCC"/><w:bottom w:val="single" w:sz="4" w:color="CCCCCC"/><w:right w:val="single" w:sz="4" w:color="CCCCCC"/><w:insideH w:val="single" w:sz="4" w:color="CCCCCC"/><w:insideV w:val="single" w:sz="4" w:color="CCCCCC"/></w:tblBorders></w:tblPr></w:style>
<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/></w:style>
</w:styles>'''

NUMBERING = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8226;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>'''

DOC_TMPL = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>{body}
<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
</w:body></w:document>'''

def main():
    with open(SRC, encoding="utf-8") as f:
        md = f.read()
    # unwrap HTML-comment-hidden flow blocks (comment keeps GitHub clean)
    md = re.sub(r"<!--\s*(::flow::.*?::endflow::)\s*-->", r"\1", md, flags=re.S)
    blocks = parse(md)
    document = DOC_TMPL.format(body=body_xml(blocks))
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("_rels/.rels", RELS)
        z.writestr("word/_rels/document.xml.rels", DOC_RELS)
        z.writestr("word/styles.xml", STYLES)
        z.writestr("word/numbering.xml", NUMBERING)
        z.writestr("word/document.xml", document)
    print(f"Wrote {OUT} ({len(blocks)} blocks)")

if __name__ == "__main__":
    main()

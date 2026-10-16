#!/usr/bin/env python3
"""
Build SPARKS_AI_Search_Proposal.html from PROPOSAL.md using only the standard library.
Open in a browser and use Print -> Save as PDF. Print CSS included.
Supports the same Markdown subset as build_docx.py.
"""
import re

SRC = "PROPOSAL.md"
OUT = "SPARKS_AI_Search_Proposal.html"

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def inline(text):
    text = esc(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    # [text](url)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text

def convert(md):
    out = []
    lines = md.splitlines()
    i = 0
    list_mode = None  # 'ul' or 'ol'
    def close_list():
        nonlocal list_mode
        if list_mode:
            out.append(f"</{list_mode}>")
            list_mode = None
    while i < len(lines):
        s = lines[i].rstrip()
        st = s.strip()
        # ---- custom ::flow:: ... ::endflow:: block -> styled 5-box diagram ----
        if st.startswith("::flow::"):
            close_list()
            title = st[len("::flow::"):].strip()
            i += 1
            steps = []   # (heading, body)
            notes = []
            buf = ""
            def flush(b):
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
                    notes.append(ln[len("::note::"):].strip())
                    i += 1; continue
                buf += " " + ln
                while "||" in buf:
                    part, _, buf = buf.partition("||")
                    flush(part)
                i += 1
            flush(buf)
            i += 1  # skip ::endflow::
            html = ["<div class='flow-wrap'>"]
            if title: html.append(f"<div class='flow-title'>{inline(title)}</div>")
            html.append("<div class='flow'>")
            for idx, (h, body) in enumerate(steps):
                cls = f"flow-box c{idx % 5}"
                html.append(f"<div class='{cls}'><div class='fb-h'>{inline(h)}</div>"
                            f"<div class='fb-b'>{inline(body)}</div></div>")
                if idx < len(steps) - 1:
                    html.append("<div class='flow-arrow'>&#9654;</div>")
            html.append("</div>")
            if notes:
                html.append("<ul class='flow-notes'>" +
                            "".join(f"<li>{inline(n)}</li>" for n in notes) + "</ul>")
            html.append("</div>")
            out.append("".join(html))
            continue
        # ---- mermaid code fence: skip in HTML (flow box already shown) ----
        if st.startswith("```mermaid"):
            while i < len(lines) and not lines[i].strip().startswith("```") or lines[i].strip() == "```mermaid":
                i += 1
                if i < len(lines) and lines[i].strip() == "```":
                    break
            i += 1
            continue
        # table
        if st.startswith("|") and st.endswith("|"):
            close_list()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(set(c) <= set("-: ") and c for c in cells):
                    rows.append(cells)
                i += 1
            out.append("<table>")
            for ri, r in enumerate(rows):
                tag = "th" if ri == 0 else "td"
                out.append("<tr>" + "".join(f"<{tag}>{inline(c)}</{tag}>" for c in r) + "</tr>")
            out.append("</table>")
            continue
        if not st:
            close_list(); i += 1; continue
        if s.startswith("### "):
            close_list(); out.append(f"<h3>{inline(s[4:])}</h3>")
        elif s.startswith("## "):
            close_list(); out.append(f"<h2>{inline(s[3:])}</h2>")
        elif s.startswith("# "):
            close_list(); out.append(f"<h1>{inline(s[2:])}</h1>")
        elif st == "---":
            close_list(); out.append("<hr/>")
        elif st.startswith("> "):
            close_list(); out.append(f"<blockquote>{inline(st[2:])}</blockquote>")
        elif re.match(r"^\s*[-*]\s+", s):
            if list_mode != "ul": close_list(); out.append("<ul>"); list_mode = "ul"
            item = re.sub(r"^\s*[-*]\s+", "", s)
            out.append(f"<li>{inline(item)}</li>")
        elif re.match(r"^\s*\d+\.\s+", s):
            if list_mode != "ol": close_list(); out.append("<ol>"); list_mode = "ol"
            item = re.sub(r"^\s*\d+\.\s+", "", s)
            out.append(f"<li>{inline(item)}</li>")
        else:
            close_list(); out.append(f"<p>{inline(s)}</p>")
        i += 1
    close_list()
    return "\n".join(out)

CSS = """
:root { --navy:#1F3864; --blue:#2E74B5; }
* { box-sizing: border-box; }
body { font-family: Calibri, 'Segoe UI', Arial, sans-serif; color:#222; line-height:1.5;
       max-width: 900px; margin: 2rem auto; padding: 0 1.5rem; }
h1 { color: var(--navy); font-size: 1.9rem; margin: 1.4rem 0 .6rem; }
h2 { color: var(--blue); font-size: 1.35rem; border-bottom: 2px solid var(--blue);
     padding-bottom: 4px; margin: 1.6rem 0 .6rem; }
h3 { color: var(--blue); font-size: 1.1rem; margin: 1.1rem 0 .4rem; }
p, li { font-size: .97rem; }
code { font-family: Consolas, monospace; background:#f4f6f8; color:#A6261D;
       padding: 1px 4px; border-radius: 3px; font-size: .9em; }
blockquote { margin:.6rem 0; padding:.4rem .9rem; border-left:3px solid var(--blue);
             background:#f6f9fc; color:#555; font-style: italic; }
table { border-collapse: collapse; width:100%; margin: .8rem 0; font-size:.92rem; }
th, td { border:1px solid #ccc; padding:6px 9px; text-align:left; vertical-align:top; }
th { background:#eef2f7; }
hr { border:0; border-top:1px solid #ccc; margin:1.4rem 0; }
a { color: var(--blue); }
/* ---- flow diagram ---- */
.flow-wrap { margin: 1rem 0 1.4rem; }
.flow-title { text-align:center; font-weight:700; color:var(--navy); font-size:1.05rem; margin-bottom:.7rem; }
.flow { display:flex; align-items:stretch; justify-content:center; flex-wrap:nowrap; gap:0; }
.flow-box { flex:1 1 0; min-width:0; border:2px solid; border-radius:10px; padding:10px 10px;
            text-align:center; background:#fff; }
.flow-box .fb-h { font-weight:700; font-size:.9rem; margin-bottom:5px; }
.flow-box .fb-b { font-size:.76rem; line-height:1.35; color:#333; }
.flow-box.c0 { border-color:#6C8EBF; background:#DAE8FC; }
.flow-box.c1 { border-color:#D79B00; background:#FFE6CC; }
.flow-box.c2 { border-color:#9673A6; background:#E1D5E7; }
.flow-box.c3 { border-color:#82B366; background:#D5E8D4; }
.flow-box.c4 { border-color:#6C8EBF; background:#DAE8FC; }
.flow-arrow { display:flex; align-items:center; color:#2E74B5; font-size:1rem; padding:0 4px; }
.flow-notes { margin:.6rem 0 0; font-size:.82rem; color:#444; }
@media print {
  .flow-box .fb-b { font-size:8pt; }
  .flow-wrap, .flow { page-break-inside: avoid; }
}
@media print {
  body { margin:0; max-width:none; font-size:11pt; }
  h1 { font-size:18pt; } h2 { font-size:14pt; } h3 { font-size:12pt; }
  h2, h3 { page-break-after: avoid; }
  table, blockquote, tr { page-break-inside: avoid; }
  a { color:#222; text-decoration:none; }
}
"""

def main():
    with open(SRC, encoding="utf-8") as f:
        md = f.read()
    md = re.sub(r"<!--\s*(::flow::.*?::endflow::)\s*-->", r"\1", md, flags=re.S)
    body = convert(md)
    html = (f"<!doctype html><html lang='en'><head><meta charset='utf-8'>"
            f"<meta name='viewport' content='width=device-width, initial-scale=1'>"
            f"<title>SPARKS AI Search — Proposal</title><style>{CSS}</style></head>"
            f"<body>{body}</body></html>")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"Wrote {OUT} ({len(body)} chars)")

if __name__ == "__main__":
    main()

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

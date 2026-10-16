#!/usr/bin/env python3
"""
Generate clean, self-contained PDF flow diagrams (no external libraries, no draw.io).

Produces landscape A4-ish PDFs with 5 evenly-spaced rounded boxes connected by
straight horizontal arrows (no jumbled/curved connectors), with word-wrapped text.

Outputs:
  Option 1 - RAG.pdf
  Option 2 - Agentic.pdf
"""
import zlib

# ---- minimal PDF primitives -------------------------------------------------
# Page: landscape, 842 x 595 pt (A4 landscape).
PW, PH = 842.0, 595.0

def esc(s):
    return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")

# Helvetica char widths (per 1000 units) — enough for decent wrapping.
_HELV = {
    ' ':278,'!':278,'"':355,'#':556,'$':556,'%':889,'&':667,"'":191,'(':333,')':333,
    '*':389,'+':584,',':278,'-':333,'.':278,'/':278,'0':556,'1':556,'2':556,'3':556,
    '4':556,'5':556,'6':556,'7':556,'8':556,'9':556,':':278,';':278,'<':584,'=':584,
    '>':584,'?':556,'@':1015,'A':667,'B':667,'C':722,'D':722,'E':667,'F':611,'G':778,
    'H':722,'I':278,'J':500,'K':667,'L':556,'M':833,'N':722,'O':778,'P':667,'Q':778,
    'R':722,'S':667,'T':611,'U':722,'V':667,'W':944,'X':667,'Y':667,'Z':611,'[':278,
    '\\':278,']':278,'^':469,'_':556,'`':333,'a':556,'b':556,'c':500,'d':556,'e':556,
    'f':278,'g':556,'h':556,'i':222,'j':222,'k':500,'l':222,'m':833,'n':556,'o':556,
    'p':556,'q':556,'r':333,'s':500,'t':278,'u':556,'v':500,'w':722,'x':500,'y':500,
    'z':500,'{':334,'|':260,'}':334,'~':584,
}
def _tw(s, size, bold=False):
    w = sum(_HELV.get(c, 556) for c in s) / 1000.0 * size
    return w * (1.03 if bold else 1.0)

def wrap(text, size, max_w, bold=False):
    words = text.split()
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if _tw(trial, size, bold) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur); cur = w
    if cur:
        lines.append(cur)
    return lines

class Canvas:
    def __init__(self):
        self.ops = []
    def rgb(self, r, g, b):          # 0-255
        return f"{r/255:.3f} {g/255:.3f} {b/255:.3f}"
    def rrect(self, x, y, w, h, r, fill, stroke, sw=2.0):
        # rounded rectangle via Bezier corners
        k = 0.5523 * r
        self.ops.append(f"{fill} rg {stroke} RG {sw:.2f} w")
        p = []
        p.append(f"{x+r:.2f} {y:.2f} m")
        p.append(f"{x+w-r:.2f} {y:.2f} l")
        p.append(f"{x+w-r+k:.2f} {y:.2f} {x+w:.2f} {y+r-k:.2f} {x+w:.2f} {y+r:.2f} c")
        p.append(f"{x+w:.2f} {y+h-r:.2f} l")
        p.append(f"{x+w:.2f} {y+h-r+k:.2f} {x+w-r+k:.2f} {y+h:.2f} {x+w-r:.2f} {y+h:.2f} c")
        p.append(f"{x+r:.2f} {y+h:.2f} l")
        p.append(f"{x+r-k:.2f} {y+h:.2f} {x:.2f} {y+h-r+k:.2f} {x:.2f} {y+h-r:.2f} c")
        p.append(f"{x:.2f} {y+r:.2f} l")
        p.append(f"{x:.2f} {y+r-k:.2f} {x+r-k:.2f} {y:.2f} {x+r:.2f} {y:.2f} c")
        self.ops.append(" ".join(p) + " B")
    def text(self, x, y, s, size, color, bold=False):
        font = "F2" if bold else "F1"
        self.ops.append(f"BT /{font} {size:.1f} Tf {color} rg "
                         f"1 0 0 1 {x:.2f} {y:.2f} Tm ({esc(s)}) Tj ET")
    def ctext(self, cx, y, s, size, color, bold=False):
        self.text(cx - _tw(s, size, bold) / 2, y, s, size, color, bold)
    def arrow(self, x1, y, x2, color, sw=2.5):
        self.ops.append(f"{color} RG {sw:.2f} w {x1:.2f} {y:.2f} m {x2-6:.2f} {y:.2f} l S")
        # filled triangle head
        self.ops.append(f"{color} rg {x2:.2f} {y:.2f} m {x2-8:.2f} {y+4.5:.2f} l "
                         f"{x2-8:.2f} {y-4.5:.2f} l f")
    def stream(self):
        return "\n".join(self.ops).encode("latin-1", "replace")

def build_pdf(path, title, subtitle, steps, notes):
    """steps: list of (heading, body). Draws 5 boxes + arrows + title + notes."""
    c = Canvas()
    navy = c.rgb(31, 56, 100)
    grey = c.rgb(90, 90, 90)
    dark = c.rgb(34, 34, 34)
    palette = [  # (fill, edge) matching the deck colors
        (c.rgb(218,232,252), c.rgb(108,142,191)),
        (c.rgb(255,230,204), c.rgb(215,155,0)),
        (c.rgb(225,213,231), c.rgb(150,115,166)),
        (c.rgb(213,232,212), c.rgb(130,179,102)),
        (c.rgb(218,232,252), c.rgb(108,142,191)),
    ]
    # title
    c.ctext(PW/2, PH-55, title, 20, navy, bold=True)
    c.ctext(PW/2, PH-78, subtitle, 11, grey)

    # layout boxes
    n = len(steps)
    margin = 36
    gap = 34                     # space for arrow between boxes
    total_gap = gap * (n - 1)
    box_w = (PW - 2*margin - total_gap) / n
    box_h = 210
    box_y = (PH - box_h) / 2 - 10
    cx0 = margin

    centers = []
    for i, (h, body) in enumerate(steps):
        x = cx0 + i * (box_w + gap)
        fill, edge = palette[i % len(palette)]
        c.rrect(x, box_y, box_w, box_h, 12, fill, edge, sw=2.2)
        # heading (wrapped, centered near top)
        cxc = x + box_w/2
        hlines = wrap(h, 13, box_w-18, bold=True)
        ty = box_y + box_h - 26
        for hl in hlines:
            c.ctext(cxc, ty, hl, 13, navy, bold=True); ty -= 16
        ty -= 6
        # body (wrapped, centered)
        for bl in wrap(body, 9.5, box_w-20):
            c.ctext(cxc, ty, bl, 9.5, dark); ty -= 13
        centers.append((x, x+box_w, box_y+box_h/2))

    # arrows between consecutive boxes
    arrow_col = c.rgb(46, 116, 181)
    for i in range(n-1):
        x_right = centers[i][1]
        x_left = centers[i+1][0]
        yc = centers[i][2]
        c.arrow(x_right+6, yc, x_left-4, arrow_col, sw=2.6)

    # notes under the row
    ny = box_y - 24
    for note in notes:
        c.text(margin, ny, "\u2022  " + note, 9.5, grey); ny -= 15

    _write(path, c.stream())

def _write(path, content):
    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PW:.0f} {PH:.0f}] "
                f"/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>"
                .encode())
    comp = zlib.compress(content)
    objs.append(b"<< /Length " + str(len(comp)).encode() + b" /Filter /FlateDecode >>\nstream\n"
                + comp + b"\nendstream")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>")

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, o in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs)+1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF"
            .encode())
    with open(path, "wb") as f:
        f.write(out)

# ---- content (matches the proposal flows / your images) ---------------------
OPTION1 = [
    ("SPARKS Data",
     "Read-only source. Reuse current domain JSON where sufficient; enrich or create AI-specific domain JSON for gaps."),
    ("AI Data Prep",
     "Normalize and curate approved investigation, vehicle, equipment, test and reference content. Preserve source record identifiers."),
    ("RAG Search Content",
     "Store curated content in an approved AI data layer and index embeddings in a vector store."),
    ("Bedrock + Claude",
     "Retrieve relevant chunks, apply metadata filters, and generate a grounded answer with source citations."),
    ("Ask SPARKS",
     "Natural-language questions, summaries, similar cases, citations and follow-up questions in the SPARKS UI."),
]
OPTION1_NOTES = [
    "No direct agent access to operational PostgreSQL is required.",
    "Coverage can expand beyond today's search JSON by enriching the AI search content.",
]

OPTION2 = [
    ("Ask SPARKS",
     "User asks one natural-language question, including multi-part comparisons or follow-ups."),
    ("Agent Orchestrator",
     "Understand intent, plan steps, select approved tools, combine results and enforce guardrails."),
    ("Approved Tools",
     "Existing OpenSearch exact/filter search + semantic/vector retrieval + read-only record/detail APIs."),
    ("Claude",
     "Synthesize results, reason across retrieved records, and generate a grounded response."),
    ("Response",
     "Answer + structured results + source links/citations + follow-up questions."),
]
OPTION2_NOTES = [
    "No unrestricted SQL tool.",
    "Existing OpenSearch becomes one tool; RAG / vector retrieval becomes another.",
]

if __name__ == "__main__":
    build_pdf("Option 1 - RAG.pdf",
              "Option 1 - Generative AI / RAG Search",
              "Separate AI retrieval path; current OpenSearch indexing remains untouched",
              OPTION1, OPTION1_NOTES)
    build_pdf("Option 2 - Agentic.pdf",
              "Option 2 - Agentic Hybrid Search",
              "An orchestration layer chooses approved search tools for complex, multi-step questions",
              OPTION2, OPTION2_NOTES)
    print("Wrote: Option 1 - RAG.pdf, Option 2 - Agentic.pdf")

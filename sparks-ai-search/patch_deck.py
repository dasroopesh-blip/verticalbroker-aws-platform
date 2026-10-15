#!/usr/bin/env python3
"""
Surgically fix Option-numbering on slides 8, 15, 16 of SPARKS_AI_Search_Deck.pptx.
Keeps every other part byte-for-byte so the file stays a valid, openable PowerPoint.
Only exact-match string replacements inside the three slide XML parts.
"""
import zipfile, sys

SRC = "SPARKS_AI_Search_Deck.pptx"
OUT = "SPARKS_AI_Search_Deck.pptx"  # overwrite in place

# part -> list of (old, new) exact replacements (text as it appears in <a:t>)
PATCHES = {
    "ppt/slides/slide8.xml": [
        ("Tool: semanticSearch() - the Option 2 vector corpus.",
         "Tool: semanticSearch() - the Option 1 vector corpus."),
        ("Best for complex, multi-step questions. An evolution of Option 2 - same corpus, same citations.",
         "Best for complex, multi-step questions. An evolution of Option 1 - same corpus, same citations."),
    ],
    "ppt/slides/slide15.xml": [
        ("Recommendation: build Option 2 (RAG) first - governable near-term value - so Option 3 (Agentic) is additive.",
         "Recommendation: build Option 1 (RAG) first - governable near-term value - so Option 2 (Agentic) is additive."),
        ("Phase 3 Agentic: agent + tools for multi-step questions (higher).",
         "Phase 3 Agentic (Option 2): agent + tools for multi-step questions (higher)."),
    ],
    "ppt/slides/slide16.xml": [
        # note: in XML the arrows are &gt; and ampersand already escaped; match the stored form
        ("Then: provision Dev via Terraform/Jenkins -&gt; backfill -&gt; evaluate with SMEs -&gt; pilot -&gt; decide on Prod / Option 3.",
         "Then: provision Dev via Terraform/Jenkins -&gt; backfill -&gt; evaluate with SMEs -&gt; pilot -&gt; decide on Prod / Option 2."),
    ],
}

def main():
    zin = zipfile.ZipFile(SRC, "r")
    # read everything first (can't read + write same file simultaneously)
    parts = {i.filename: zin.read(i.filename) for i in zin.infolist()}
    infos = zin.infolist()
    zin.close()

    report = []
    for part, subs in PATCHES.items():
        if part not in parts:
            print(f"!! missing part {part}", file=sys.stderr); sys.exit(1)
        xml = parts[part].decode("utf-8")
        for old, new in subs:
            if old not in xml:
                print(f"!! NOT FOUND in {part}:\n   {old}", file=sys.stderr)
                sys.exit(2)
            xml = xml.replace(old, new)
            report.append((part, old, new))
        parts[part] = xml.encode("utf-8")

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in infos:
            # preserve original compression type per entry
            data = parts[info.filename]
            zout.writestr(info, data)

    print(f"Patched {OUT}. Replacements applied:")
    for part, old, new in report:
        print(f"  [{part}]")
        print(f"    - {old}")
        print(f"    + {new}")

if __name__ == "__main__":
    main()

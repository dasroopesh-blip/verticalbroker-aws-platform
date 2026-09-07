"""Text chunking for embedding.

Splits filing text into overlapping, roughly token-sized windows. We approximate
tokens as whitespace words (~1.3 tokens/word for English is close enough for
chunk sizing) to avoid a heavyweight tokenizer dependency. Overlap preserves
context across chunk boundaries so answers don't get cut mid-thought.
"""

from __future__ import annotations

import re

# Detect common SEC "Item" section headers so chunks can carry a section label
# used later for citations (e.g. "Item 1A. Risk Factors").
_ITEM_RE = re.compile(r"(Item\s+\d+[A-Z]?\.?\s+[A-Z][A-Za-z ]{2,40})")


def _detect_section(text: str) -> str | None:
    match = _ITEM_RE.search(text)
    return match.group(1).strip() if match else None


def chunk_text(text: str, chunk_size_tokens: int = 800, overlap_tokens: int = 120) -> list[tuple[str, str | None]]:
    """Split text into overlapping chunks.

    Args:
        text: The full filing text.
        chunk_size_tokens: Approx target chunk size (in words).
        overlap_tokens: Approx overlap between consecutive chunks (in words).

    Returns:
        List of ``(chunk_text, section_label_or_None)`` tuples.
    """
    words = text.split()
    if not words:
        return []
    step = max(1, chunk_size_tokens - overlap_tokens)
    chunks: list[tuple[str, str | None]] = []
    for start in range(0, len(words), step):
        window = words[start : start + chunk_size_tokens]
        if not window:
            break
        chunk = " ".join(window)
        chunks.append((chunk, _detect_section(chunk)))
        if start + chunk_size_tokens >= len(words):
            break
    return chunks

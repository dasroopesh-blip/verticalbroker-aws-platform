"""Unit tests for the text chunker."""

from __future__ import annotations

import pytest

from filings_assistant.search.chunker import chunk_text

pytestmark = pytest.mark.unit


def test_empty_text_returns_no_chunks() -> None:
    assert chunk_text("") == []


def test_short_text_single_chunk() -> None:
    chunks = chunk_text("hello world", chunk_size_tokens=100, overlap_tokens=10)
    assert len(chunks) == 1
    assert chunks[0][0] == "hello world"


def test_chunks_overlap() -> None:
    words = " ".join(str(i) for i in range(100))
    chunks = chunk_text(words, chunk_size_tokens=30, overlap_tokens=10)
    assert len(chunks) > 1
    # Consecutive chunks should share overlapping tokens.
    first_tail = chunks[0][0].split()[-10:]
    second_head = chunks[1][0].split()[:10]
    assert set(first_tail) & set(second_head)


def test_section_detection() -> None:
    text = "Item 1A. Risk Factors The company faces supply chain risk " * 20
    chunks = chunk_text(text, chunk_size_tokens=50, overlap_tokens=5)
    assert any(c[1] and c[1].startswith("Item 1A") for c in chunks)

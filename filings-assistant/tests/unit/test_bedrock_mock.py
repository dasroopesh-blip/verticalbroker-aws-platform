"""Unit tests for the mock Bedrock client."""

from __future__ import annotations

import pytest

from filings_assistant.common.bedrock import MockBedrockClient

pytestmark = pytest.mark.unit


def test_embeddings_are_deterministic(settings) -> None:
    client = MockBedrockClient(settings)
    a = client.embed_texts(["supply chain risk"])[0]
    b = client.embed_texts(["supply chain risk"])[0]
    assert a == b
    assert len(a) == settings.embedding_dimensions


def test_embeddings_are_normalized(settings) -> None:
    client = MockBedrockClient(settings)
    vec = client.embed_texts(["cybersecurity regulation risk"])[0]
    norm = sum(v * v for v in vec) ** 0.5
    assert norm == pytest.approx(1.0, abs=1e-6)


def test_similar_text_more_similar_than_unrelated(settings) -> None:
    client = MockBedrockClient(settings)

    def cos(x, y):
        return sum(a * b for a, b in zip(x, y, strict=True))

    base = client.embed_texts(["supply chain risk tariffs"])[0]
    similar = client.embed_texts(["supply chain risk"])[0]
    unrelated = client.embed_texts(["dividend buyback repurchase"])[0]
    assert cos(base, similar) > cos(base, unrelated)


def test_converse_returns_answer(settings) -> None:
    client = MockBedrockClient(settings)
    resp = client.converse("system", [{"role": "user", "content": [{"text": "hello"}]}])
    assert resp["text"]
    assert resp["stop_reason"] == "end_turn"

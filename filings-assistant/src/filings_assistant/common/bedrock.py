"""Amazon Bedrock client wrapper.

Two responsibilities:
    1. ``embed_texts``   -> Titan Text Embeddings V2 (text -> vector)
    2. ``converse``      -> Claude Sonnet reasoning, with tool-use support

Design choices:
    - Model IDs come from Settings (configurable, region-dependent).
    - A ``MockBedrockClient`` provides deterministic, offline behavior so the
      whole RAG pipeline runs with no AWS account/network. It is selected
      automatically when ``FA_USE_MOCK_BEDROCK=true`` or boto3 is unavailable.
    - The real client uses the Bedrock Runtime ``converse`` API, which offers a
      unified message + tool-use interface across models.
"""

from __future__ import annotations

import hashlib
import json
import math
from typing import Any, Protocol

from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.common.retry import RetryConfig, ThrottlingException, retry_with_backoff

logger = get_logger("common.bedrock")

_EMBED_RETRY = RetryConfig(max_attempts=4, base_delay=1.0, retryable_exceptions=(ThrottlingException, ConnectionError))


class BedrockClient(Protocol):
    """Interface implemented by both the real and mock clients."""

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        """Return one embedding vector per input text."""
        ...

    def converse(
        self,
        system: str,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 1024,
    ) -> dict[str, Any]:
        """Return a normalized response: {text, tool_uses, stop_reason}."""
        ...


# ---------------------------------------------------------------------------
# Real Bedrock implementation
# ---------------------------------------------------------------------------
class AwsBedrockClient:
    """Calls Amazon Bedrock Runtime for embeddings and reasoning."""

    def __init__(self, settings: Settings) -> None:
        import boto3  # imported lazily so mock mode needs no AWS deps

        self._settings = settings
        self._runtime = boto3.client("bedrock-runtime", region_name=settings.aws_region)

    @retry_with_backoff(_EMBED_RETRY)
    def _embed_one(self, text: str) -> list[float]:
        body = json.dumps({"inputText": text, "dimensions": self._settings.embedding_dimensions})
        resp = self._runtime.invoke_model(modelId=self._settings.bedrock_embedding_model_id, body=body)
        payload = json.loads(resp["body"].read())
        return payload["embedding"]

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        # Titan embeds one input at a time; batch at the call-site level.
        return [self._embed_one(t) for t in texts]

    def converse(
        self,
        system: str,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 1024,
    ) -> dict[str, Any]:
        kwargs: dict[str, Any] = {
            "modelId": self._settings.bedrock_reasoning_model_id,
            "system": [{"text": system}],
            "messages": messages,
            "inferenceConfig": {"maxTokens": max_tokens, "temperature": 0.0},
        }
        if tools:
            kwargs["toolConfig"] = {"tools": tools}
        resp = self._runtime.converse(**kwargs)
        return _normalize_converse(resp)

    def close(self) -> None:  # pragma: no cover - trivial
        self._runtime.close()


def _normalize_converse(resp: dict[str, Any]) -> dict[str, Any]:
    """Flatten a Bedrock converse response into a simple dict."""
    content = resp.get("output", {}).get("message", {}).get("content", [])
    text_parts = [c["text"] for c in content if "text" in c]
    tool_uses = [c["toolUse"] for c in content if "toolUse" in c]
    return {
        "text": "\n".join(text_parts).strip(),
        "tool_uses": tool_uses,
        "stop_reason": resp.get("stopReason", "end_turn"),
    }


# ---------------------------------------------------------------------------
# Mock implementation (offline / $0 dev)
# ---------------------------------------------------------------------------
class MockBedrockClient:
    """Deterministic, dependency-free stand-in for Bedrock.

    Embeddings are derived from token hashes projected into a fixed-dimension
    vector and L2-normalized, so semantically identical text yields identical
    vectors and overlapping text yields higher cosine similarity. Good enough
    to exercise and test the full retrieval pipeline without any network.
    """

    def __init__(self, settings: Settings) -> None:
        self._dim = settings.embedding_dimensions

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        return [self._embed_one(t) for t in texts]

    def _embed_one(self, text: str) -> list[float]:
        vec = [0.0] * self._dim
        for token in text.lower().split():
            h = int(hashlib.md5(token.encode()).hexdigest(), 16)
            idx = h % self._dim
            vec[idx] += 1.0
        norm = math.sqrt(sum(v * v for v in vec)) or 1.0
        return [v / norm for v in vec]

    def converse(
        self,
        system: str,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int = 1024,
    ) -> dict[str, Any]:
        # The mock never calls tools; it just synthesizes an answer from any
        # context already present in the last user message so the agent's
        # final-answer path can be exercised end to end.
        last_user = next((m for m in reversed(messages) if m.get("role") == "user"), None)
        text = ""
        if last_user:
            for block in last_user.get("content", []):
                if isinstance(block, dict) and "text" in block:
                    text = block["text"]
        answer = (
            "[MOCK ANSWER] Based on the retrieved filing excerpts, here is a "
            "grounded summary. (Set FA_USE_MOCK_BEDROCK=false with Bedrock "
            "access for real Claude reasoning.)\n\n" + text[:600]
        )
        return {"text": answer, "tool_uses": [], "stop_reason": "end_turn"}


def get_bedrock_client(settings: Settings | None = None) -> BedrockClient:
    """Factory: return the real or mock Bedrock client based on settings."""
    settings = settings or get_settings()
    if settings.use_mock_bedrock:
        logger.info("Using MockBedrockClient (offline mode)")
        return MockBedrockClient(settings)
    try:
        return AwsBedrockClient(settings)
    except Exception as exc:  # boto3 missing or credentials issue
        logger.warning("Falling back to MockBedrockClient", error=str(exc))
        return MockBedrockClient(settings)

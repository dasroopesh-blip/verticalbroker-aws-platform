"""Query understanding — the relevance step before retrieval.

Turns a raw user prompt into (a) a cleaner search query and (b) structured
metadata filters (ticker, form, section) that narrow retrieval. Better input to
the retriever = better relevance downstream.

Two implementations:
    - LLM-based (Bedrock/Claude): asks the model to return a small JSON object.
    - Heuristic fallback: regex/keyword extraction that runs offline and in
      tests (also used if the LLM output can't be parsed).

Extracted filters are applied as OpenSearch term filters, e.g. {"ticker": "AAPL",
"form": "10-K"}. This keeps the expensive vector/rerank work focused on the
right subset of a tenant's corpus.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

from filings_assistant.common.bedrock import BedrockClient, get_bedrock_client
from filings_assistant.common.logging import get_logger
from filings_assistant.models import FilingForm

logger = get_logger("agent.query_understanding")

_TICKER_RE = re.compile(r"\b([A-Z]{1,5})\b")
_FORM_RE = re.compile(r"\b(10-?K|10-?Q|8-?K)\b", re.IGNORECASE)
_SECTION_RE = re.compile(r"\bItem\s+\d+[A-Z]?\b", re.IGNORECASE)

# Common words that look like tickers but aren't; avoids false positives.
_STOPWORD_TICKERS = {"A", "I", "AI", "US", "CEO", "CFO", "SEC", "GAAP", "RISK", "THE", "AND", "FOR", "WHAT", "DID"}


@dataclass
class UnderstoodQuery:
    """The rewritten query plus structured filters for retrieval."""

    search_query: str
    filters: dict[str, str] = field(default_factory=dict)


_SYSTEM = (
    "You extract search parameters from a financial analyst's question about SEC "
    "filings. Return ONLY a compact JSON object with keys: search_query (string, a "
    "cleaned/expanded query good for retrieval), ticker (uppercase symbol or null), "
    "form (one of 10-K, 10-Q, 8-K, or null), section (e.g. 'Item 1A' or null). No prose."
)


class QueryUnderstanding:
    """Rewrites the prompt and extracts metadata filters."""

    def __init__(self, bedrock: BedrockClient | None = None, use_llm: bool = True) -> None:
        self._bedrock = bedrock or get_bedrock_client()
        self._use_llm = use_llm

    def understand(self, prompt: str) -> UnderstoodQuery:
        if self._use_llm:
            parsed = self._llm_understand(prompt)
            if parsed is not None:
                return parsed
        return self._heuristic_understand(prompt)

    def _llm_understand(self, prompt: str) -> UnderstoodQuery | None:
        try:
            resp = self._bedrock.converse(
                system=_SYSTEM,
                messages=[{"role": "user", "content": [{"text": prompt}]}],
                max_tokens=256,
            )
            text = resp.get("text", "")
            start, end = text.find("{"), text.rfind("}")
            if start == -1 or end == -1:
                return None
            data = json.loads(text[start : end + 1])
            filters: dict[str, str] = {}
            if data.get("ticker"):
                filters["ticker"] = str(data["ticker"]).upper()
            if data.get("form"):
                filters["form"] = _normalize_form(str(data["form"]))
            if data.get("section"):
                filters["section"] = str(data["section"])
            filters = {k: v for k, v in filters.items() if v}
            return UnderstoodQuery(search_query=data.get("search_query") or prompt, filters=filters)
        except Exception as exc:
            logger.warning("LLM query understanding failed; using heuristic", error=str(exc))
            return None

    def _heuristic_understand(self, prompt: str) -> UnderstoodQuery:
        filters: dict[str, str] = {}

        form_match = _FORM_RE.search(prompt)
        if form_match:
            filters["form"] = _normalize_form(form_match.group(1))

        section_match = _SECTION_RE.search(prompt)
        if section_match:
            filters["section"] = section_match.group(0).title().replace("Item ", "Item ")

        for candidate in _TICKER_RE.findall(prompt):
            if candidate not in _STOPWORD_TICKERS:
                filters["ticker"] = candidate
                break

        return UnderstoodQuery(search_query=prompt.strip(), filters=filters)


def _normalize_form(raw: str) -> str:
    """Normalize '10k'/'10-K'/'10 K' to a canonical FilingForm value."""
    cleaned = raw.upper().replace(" ", "").replace("--", "-")
    if "-" not in cleaned:
        cleaned = cleaned[:2] + "-" + cleaned[2:]  # 10K -> 10-K, 8K -> 8-K
    try:
        return FilingForm(cleaned).value
    except ValueError:
        return ""


__all__ = ["QueryUnderstanding", "UnderstoodQuery"]

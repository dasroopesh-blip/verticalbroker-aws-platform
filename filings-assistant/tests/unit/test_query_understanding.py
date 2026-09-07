"""Unit tests for query understanding (heuristic path)."""

from __future__ import annotations

import pytest

from filings_assistant.agent.query_understanding import QueryUnderstanding

pytestmark = pytest.mark.unit


@pytest.fixture
def qu() -> QueryUnderstanding:
    # Force the heuristic path (no LLM) for deterministic offline testing.
    return QueryUnderstanding(use_llm=False)


def test_extracts_ticker(qu) -> None:
    result = qu.understand("What supply chain risks does AAPL disclose?")
    assert result.filters.get("ticker") == "AAPL"


def test_extracts_form(qu) -> None:
    result = qu.understand("Summarize the 10-K risk factors")
    assert result.filters.get("form") == "10-K"


def test_extracts_section(qu) -> None:
    result = qu.understand("What is in Item 1A for the company?")
    assert result.filters.get("section", "").lower().startswith("item 1a")


def test_ignores_stopword_tickers(qu) -> None:
    result = qu.understand("What are the AI regulation risks?")
    # "AI" is a stopword-ticker and must not be treated as a ticker filter.
    assert result.filters.get("ticker") != "AI"


def test_search_query_defaults_to_prompt(qu) -> None:
    result = qu.understand("cybersecurity exposure")
    assert result.search_query == "cybersecurity exposure"

"""SEC EDGAR client.

Fetches public company filings from the SEC's free EDGAR APIs. The SEC requires
a descriptive ``User-Agent`` header identifying your app + contact email, and
asks callers to stay under ~10 requests/second.

References (public docs):
    - Company submissions:  https://data.sec.gov/submissions/CIK##########.json
    - Ticker -> CIK map:     https://www.sec.gov/files/company_tickers.json
    - Filing documents:      https://www.sec.gov/Archives/edgar/data/...

When the network/SEC is unavailable (e.g. the offline sandbox), an offline
sample provider yields a couple of small, realistic filing documents so the
rest of the pipeline can be exercised. Selection is automatic: real fetch is
attempted first and falls back to samples on failure.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import date

import httpx

from filings_assistant.common.config import Settings, get_settings
from filings_assistant.common.logging import get_logger
from filings_assistant.models import FilingForm

logger = get_logger("ingestion.sec")

_TICKER_MAP_URL = "https://www.sec.gov/files/company_tickers.json"
_SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK{cik10}.json"


@dataclass
class RawFiling:
    """A fetched filing before it becomes a persisted ``Filing``."""

    cik: str
    ticker: str | None
    company_name: str
    form: FilingForm
    accession_number: str
    filing_date: date
    source_url: str
    text: str

    @property
    def content_sha256(self) -> str:
        return hashlib.sha256(self.text.encode("utf-8")).hexdigest()


def _clean_html(html: str) -> str:
    """Very light HTML-to-text: strip tags/scripts and collapse whitespace."""
    html = re.sub(r"(?is)<(script|style).*?>.*?</\1>", " ", html)
    text = re.sub(r"(?s)<[^>]+>", " ", html)
    text = re.sub(r"&#\d+;|&[a-z]+;", " ", text)
    return re.sub(r"\s+", " ", text).strip()


class SecEdgarClient:
    """Thin wrapper over EDGAR HTTP endpoints, with offline fallback."""

    def __init__(self, settings: Settings | None = None) -> None:
        self._settings = settings or get_settings()
        self._headers = {"User-Agent": self._settings.sec_user_agent}

    def fetch_filings(self, ticker: str, form: FilingForm, limit: int = 1) -> list[RawFiling]:
        """Fetch the most recent ``limit`` filings of ``form`` for ``ticker``."""
        try:
            return self._fetch_live(ticker.upper(), form, limit)
        except Exception as exc:
            logger.warning("SEC live fetch failed; using offline samples", ticker=ticker, error=str(exc))
            return _sample_filings(ticker.upper(), form, limit)

    # -- live fetch ---------------------------------------------------------
    def _fetch_live(self, ticker: str, form: FilingForm, limit: int) -> list[RawFiling]:
        with httpx.Client(headers=self._headers, timeout=15.0) as client:
            cik, name = self._resolve_cik(client, ticker)
            subs = client.get(_SUBMISSIONS_URL.format(cik10=cik), timeout=15.0).json()
            recent = subs["filings"]["recent"]
            results: list[RawFiling] = []
            for i, form_type in enumerate(recent["form"]):
                if form_type != form.value:
                    continue
                accession = recent["accessionNumber"][i]
                primary_doc = recent["primaryDocument"][i]
                acc_nodash = accession.replace("-", "")
                url = f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{acc_nodash}/{primary_doc}"
                doc = client.get(url, timeout=30.0)
                results.append(
                    RawFiling(
                        cik=cik, ticker=ticker, company_name=name, form=form,
                        accession_number=accession,
                        filing_date=date.fromisoformat(recent["filingDate"][i]),
                        source_url=url, text=_clean_html(doc.text),
                    )
                )
                if len(results) >= limit:
                    break
            return results

    def _resolve_cik(self, client: httpx.Client, ticker: str) -> tuple[str, str]:
        data = client.get(_TICKER_MAP_URL, timeout=15.0).json()
        for entry in data.values():
            if entry["ticker"].upper() == ticker:
                return str(entry["cik_str"]).zfill(10), entry["title"]
        raise ValueError(f"Ticker not found in SEC map: {ticker}")


# ---------------------------------------------------------------------------
# Offline sample data
# ---------------------------------------------------------------------------
_SAMPLE_TEXT = {
    "AAPL": (
        "Apple Inc. Annual Report. Item 1A. Risk Factors. The Company's business, "
        "results of operations, and financial condition are subject to various risks. "
        "The Company depends on component and product manufacturing and logistical "
        "services provided by outsourcing partners, many of which are located outside "
        "of the United States, creating supply chain concentration risk. Global and "
        "regional economic conditions, tariffs, and international trade disputes could "
        "materially adversely affect the Company. The Company is exposed to foreign "
        "exchange rate risk and to risks related to information technology system "
        "failures, network disruptions, and cybersecurity incidents."
    ),
    "MSFT": (
        "Microsoft Corporation Annual Report. Item 1A. Risk Factors. We face intense "
        "competition across all markets for our products and services. Our cloud-based "
        "services, including Azure, face evolving cybersecurity threats and outages "
        "that could harm our reputation. Government regulation of artificial "
        "intelligence, data privacy, and competition is increasing and could impose "
        "significant compliance costs and constrain how we develop and deploy AI "
        "features. Our international operations expose us to currency and geopolitical "
        "risk."
    ),
}
_DEFAULT_SAMPLE = (
    "Sample Company Annual Report. Item 1A. Risk Factors. The company is subject to "
    "market, credit, liquidity, operational, cybersecurity, and regulatory risks that "
    "could materially affect its financial condition and results of operations."
)


def _sample_filings(ticker: str, form: FilingForm, limit: int) -> list[RawFiling]:
    text = _SAMPLE_TEXT.get(ticker, _DEFAULT_SAMPLE)
    name = {"AAPL": "Apple Inc.", "MSFT": "Microsoft Corporation"}.get(ticker, f"{ticker} Inc.")
    return [
        RawFiling(
            cik=str(abs(hash(ticker)) % 10**10).zfill(10),
            ticker=ticker, company_name=name, form=form,
            accession_number=f"0000000000-24-{i:06d}",
            filing_date=date(2024, 1, 1),
            source_url=f"https://www.sec.gov/sample/{ticker}/{form.value}/{i}",
            text=text,
        )
        for i in range(limit)
    ]

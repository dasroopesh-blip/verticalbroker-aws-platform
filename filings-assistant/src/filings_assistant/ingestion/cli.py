"""CLI entrypoint for ingesting filings.

Usage:
    python -m filings_assistant.ingestion.cli --ticker AAPL --form 10-K --limit 1
    python -m filings_assistant.ingestion.cli --ticker AAPL --form 10-K --run-worker

The ``--run-worker`` flag drains the queue immediately (embed + index) so that,
in local mode, one command gives you a searchable corpus end to end.
"""

from __future__ import annotations

import argparse

from filings_assistant.models import FilingForm


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ingest SEC EDGAR filings into filings-assistant")
    parser.add_argument("--ticker", required=True, help="Ticker symbol, e.g. AAPL")
    parser.add_argument("--form", default="10-K", choices=[f.value for f in FilingForm], help="Filing form type")
    parser.add_argument("--limit", type=int, default=1, help="Max filings to fetch")
    parser.add_argument("--tenant", default=None, help="Tenant id (defaults to FA_DEFAULT_TENANT_ID)")
    parser.add_argument("--run-worker", action="store_true", help="Immediately embed + index queued filings")
    args = parser.parse_args(argv)

    # Imported here so --help works without heavy deps.
    from filings_assistant.common.tenant import TenantContext, default_tenant
    from filings_assistant.ingestion.service import IngestionService

    tenant = TenantContext.from_auth(args.tenant) if args.tenant else default_tenant()
    service = IngestionService()
    stored = service.ingest(tenant, args.ticker, FilingForm(args.form), args.limit)
    print(f"Ingested {len(stored)} new filing(s) for {args.ticker} {args.form}.")
    for f in stored:
        print(f"  - {f.filing_id}  {f.company_name}  {f.accession_number}  status={f.status.value}")

    if args.run_worker:
        from filings_assistant.worker.processor import WorkerProcessor

        processed = WorkerProcessor().drain()
        print(f"Worker indexed {processed} filing(s). Corpus is now searchable.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Market data schemas for Bronze/Silver/Gold medallion layers.

Defines typed dataclass models for market data at each processing stage:
- MarketDataRaw (Bronze): Raw data as received from Bloomberg B-Pipe / Thomson Reuters
- MarketDataSilver (Silver): Validated, deduplicated, schema-enforced data
- DailyTradeSummaryGold (Gold): Daily aggregated trade summary per instrument

All price fields use Decimal for financial precision.
All timestamps use datetime for consistency.

Requirements: 7.3 - Lambda Layers for shared data validation schemas
"""

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Optional


@dataclass
class MarketDataRaw:
    """Bronze layer: raw market data as received from source.

    Stored in S3 Bronze bucket partitioned by source/instrument_type/date.
    Immutable, versioned, encrypted with KMS CMK.
    """

    # Source identification
    source_id: str  # "bloomberg_bpipe" | "thomson_reuters"
    instrument_id: str  # ISIN or CUSIP identifier
    instrument_name: str
    instrument_type: str  # EQUITY | BOND | OPTION | ETF | FUTURES
    exchange: str  # NYSE | NASDAQ | LSE | etc.

    # Price data (Decimal for financial precision)
    bid_price: Decimal
    ask_price: Decimal
    last_price: Decimal
    volume: int

    # Timestamps
    source_timestamp: datetime  # When source generated the tick
    ingestion_timestamp: datetime  # When platform received it

    # Metadata (enriched at ingestion)
    schema_version: str  # e.g., "v2.3.1"
    partition_key: str  # "{source}/{instrument_type}/{date}"
    sequence_number: str  # Kinesis sequence for ordering
    shard_id: str  # Source Kinesis shard

    # Quality markers
    is_delayed: bool = False  # True if delayed quote
    market_status: str = "OPEN"  # PRE_MARKET | OPEN | CLOSED | AFTER_HOURS


@dataclass
class MarketDataSilver:
    """Silver layer: validated, deduplicated, schema-enforced data.

    Stored in S3 Silver bucket as Parquet with Snappy compression,
    partitioned by instrument_type and trade_date.
    """

    # Primary identifiers
    instrument_id: str
    instrument_type: str
    trade_date: str  # Partition key: YYYY-MM-DD

    # Price data (validated)
    bid_price: Decimal
    ask_price: Decimal
    last_price: Decimal
    mid_price: Decimal  # Computed: (bid + ask) / 2
    spread: Decimal  # Computed: ask - bid
    volume: int

    # Timestamps and lineage
    source_timestamp: datetime
    processing_job_id: str  # Lineage: which Glue job produced this
    quality_score: float  # 0.0 - 1.0 from data quality checks
    dedup_key: str  # Hash of instrument_id + timestamp + source


@dataclass
class DailyTradeSummaryGold:
    """Gold layer: daily aggregated trade summary per instrument.

    Optimized for Query Engine (Athena) access with partition elimination.
    Produced by Silver-to-Gold ETL aggregation job.
    """

    # Primary identifiers
    instrument_id: str
    instrument_name: str
    trade_date: str  # Partition key: YYYY-MM-DD

    # OHLCV data
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal
    vwap: Decimal  # Volume-weighted average price

    # Volume metrics
    total_volume: int
    trade_count: int
    turnover: Decimal  # price * quantity summed

    # Derived metrics
    daily_return_pct: Decimal
    volatility_20d: Decimal  # 20-day rolling volatility
    avg_spread: Decimal

    # Metadata
    last_updated: datetime
    source_record_count: int
    quality_score: float  # Aggregate quality from Silver inputs


__all__ = [
    "MarketDataRaw",
    "MarketDataSilver",
    "DailyTradeSummaryGold",
]

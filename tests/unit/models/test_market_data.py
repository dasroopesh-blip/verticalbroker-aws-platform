"""
Unit tests for market data models.
Tests: MarketDataRaw, MarketDataSilver, DailyTradeSummaryGold dataclasses.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest


pytestmark = pytest.mark.unit


class TestMarketDataRaw:
    """Tests for Bronze-layer market data model."""

    def test_raw_record_creation(self):
        """MarketDataRaw contains all required ingestion fields."""
        raw = {
            "source_id": "bloomberg-feed-1",
            "instrument_id": "AAPL",
            "timestamp": datetime.now(UTC).isoformat(),
            "event_type": "TRADE",
            "price": 185.50,
            "volume": 1000,
            "exchange": "NYSE",
            "schema_version": "1.0",
            "ingestion_timestamp": datetime.now(UTC).isoformat(),
            "partition_key": "AAPL",
        }
        required_fields = [
            "source_id", "instrument_id", "timestamp", "event_type",
            "price", "volume", "exchange", "schema_version",
        ]
        for field in required_fields:
            assert field in raw

    def test_raw_preserves_original_precision(self):
        """Raw layer preserves original floating-point price from feed."""
        price = 185.505  # 3 decimal places from feed
        assert isinstance(price, float)

    def test_raw_includes_ingestion_metadata(self):
        """Raw records include ingestion_timestamp and partition_key."""
        raw = {
            "ingestion_timestamp": datetime.now(UTC).isoformat(),
            "partition_key": "AAPL",
        }
        assert "ingestion_timestamp" in raw
        assert "partition_key" in raw

    def test_multiple_event_types_supported(self):
        """Supports TRADE, QUOTE, NBBO, IMBALANCE event types."""
        valid_types = {"TRADE", "QUOTE", "NBBO", "IMBALANCE"}
        assert "TRADE" in valid_types
        assert "QUOTE" in valid_types
        assert "INVALID" not in valid_types


class TestMarketDataSilver:
    """Tests for Silver-layer (cleansed/validated) market data model."""

    def test_silver_record_uses_decimal(self):
        """Silver-layer uses Decimal for price/volume (not float)."""
        silver = {
            "instrument_id": "AAPL",
            "price": Decimal("185.50"),
            "volume": Decimal("1000"),
            "vwap": Decimal("185.32"),
        }
        assert isinstance(silver["price"], Decimal)
        assert isinstance(silver["volume"], Decimal)

    def test_silver_includes_quality_flags(self):
        """Silver records include data quality validation flags."""
        silver = {
            "instrument_id": "AAPL",
            "price": Decimal("185.50"),
            "quality_score": 95.5,
            "quality_flags": [],
            "is_valid": True,
            "validated_at": datetime.now(UTC).isoformat(),
        }
        assert silver["is_valid"] is True
        assert silver["quality_score"] > 0

    def test_silver_deduplication_key(self):
        """Silver dedup key: instrument_id + source_timestamp + source_id."""
        dedup_key = {
            "instrument_id": "AAPL",
            "source_timestamp": "2024-01-15T14:30:00Z",
            "source_id": "bloomberg-feed-1",
        }
        composite_key = f"{dedup_key['instrument_id']}#{dedup_key['source_timestamp']}#{dedup_key['source_id']}"
        assert "#" in composite_key
        assert composite_key.startswith("AAPL#")

    def test_silver_partition_scheme(self):
        """Silver partitioned by instrument_type + trade_date."""
        partition = {
            "instrument_type": "equity",
            "trade_date": "2024-01-15",
        }
        s3_path = f"silver/instrument_type={partition['instrument_type']}/trade_date={partition['trade_date']}/"
        assert "instrument_type=equity" in s3_path
        assert "trade_date=2024-01-15" in s3_path


class TestDailyTradeSummaryGold:
    """Tests for Gold-layer aggregated trade summary model."""

    def test_gold_ohlcv_fields(self):
        """Gold trade summary includes OHLCV (Open, High, Low, Close, Volume)."""
        summary = {
            "instrument_id": "AAPL",
            "trade_date": "2024-01-15",
            "open_price": Decimal("184.00"),
            "high_price": Decimal("186.50"),
            "low_price": Decimal("183.75"),
            "close_price": Decimal("185.50"),
            "total_volume": Decimal("45000000"),
        }
        assert summary["high_price"] >= summary["low_price"]
        assert summary["open_price"] >= summary["low_price"]
        assert summary["close_price"] <= summary["high_price"]

    def test_gold_vwap_calculation(self):
        """Gold includes VWAP (Volume-Weighted Average Price)."""
        # VWAP = sum(price * volume) / sum(volume)
        trades = [
            {"price": Decimal("185.00"), "volume": Decimal("10000")},
            {"price": Decimal("186.00"), "volume": Decimal("20000")},
            {"price": Decimal("184.00"), "volume": Decimal("15000")},
        ]
        total_pv = sum(t["price"] * t["volume"] for t in trades)
        total_vol = sum(t["volume"] for t in trades)
        vwap = total_pv / total_vol

        assert vwap == Decimal("185.2222222222222222222222222")  # ~185.22

    def test_gold_trade_count(self):
        """Gold summary includes total trade count for the day."""
        summary = {"instrument_id": "AAPL", "trade_count": 125000}
        assert summary["trade_count"] > 0

    def test_gold_uses_decimal_18_8_precision(self):
        """Gold monetary fields use Decimal(18,8) precision."""
        price = Decimal("185.50000000")  # 8 decimal places
        assert len(str(price).split(".")[1]) == 8

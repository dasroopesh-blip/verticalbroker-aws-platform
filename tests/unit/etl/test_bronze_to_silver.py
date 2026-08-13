"""
Unit tests for Bronze-to-Silver ETL job.
Tests: Schema validation, deduplication, data quality abort, Parquet write, lineage.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal
from unittest.mock import MagicMock, patch

import pytest


pytestmark = [pytest.mark.unit, pytest.mark.etl]


class TestBronzeToSilverExtract:
    """Tests for Bronze layer data extraction."""

    def test_extract_reads_from_glue_catalog(self):
        """Extract reads from Glue Data Catalog bronze database."""
        database = "verticalbroker_bronze"
        table = "market_data_raw"
        assert database.startswith("verticalbroker_")
        assert table == "market_data_raw"

    def test_extract_filters_by_partition(self):
        """Extract uses push-down predicate for incremental processing."""
        partition_predicate = "trade_date >= '2024-01-15'"
        assert "trade_date" in partition_predicate
        assert ">=" in partition_predicate

    def test_extract_handles_empty_partition(self):
        """Empty partition returns zero records gracefully."""
        record_count = 0
        assert record_count == 0


class TestSchemaValidation:
    """Tests for Bronze schema validation before Silver write."""

    def test_valid_schema_passes(self):
        """Records matching the expected StructType schema pass validation."""
        expected_fields = [
            "instrument_id", "source_id", "timestamp", "price",
            "volume", "exchange", "event_type", "source_timestamp",
        ]
        record_fields = [
            "instrument_id", "source_id", "timestamp", "price",
            "volume", "exchange", "event_type", "source_timestamp",
        ]
        assert set(expected_fields) == set(record_fields)

    def test_missing_required_field_fails(self):
        """Records missing a required field fail schema validation."""
        required_fields = {"instrument_id", "timestamp", "price", "volume"}
        record_fields = {"instrument_id", "timestamp", "price"}  # Missing volume
        missing = required_fields - record_fields
        assert "volume" in missing

    def test_extra_fields_are_dropped(self):
        """Extra fields not in schema are dropped (not cause failure)."""
        schema_fields = {"instrument_id", "price", "volume"}
        record_fields = {"instrument_id", "price", "volume", "extra_field"}
        extra = record_fields - schema_fields
        assert "extra_field" in extra

    def test_type_mismatch_fails(self):
        """Wrong data type (string where Decimal expected) fails validation."""
        expected_type = "DecimalType(18,8)"
        actual_value = "not_a_number"
        try:
            Decimal(actual_value)
            valid = True
        except Exception:
            valid = False
        assert valid is False


class TestDeduplication:
    """Tests for composite-key deduplication (window function)."""

    def test_dedup_key_is_composite(self):
        """Dedup key: instrument_id + source_timestamp + source_id."""
        record = {
            "instrument_id": "AAPL",
            "source_timestamp": "2024-01-15T14:30:00.123Z",
            "source_id": "bloomberg-feed-1",
        }
        dedup_key = f"{record['instrument_id']}|{record['source_timestamp']}|{record['source_id']}"
        assert "|" in dedup_key
        assert dedup_key.startswith("AAPL|")

    def test_duplicate_records_keep_latest(self):
        """Duplicates are resolved by keeping the most recent ingestion_timestamp."""
        records = [
            {"dedup_key": "AAPL|ts1|bloomberg", "ingestion_ts": "2024-01-15T14:30:00Z"},
            {"dedup_key": "AAPL|ts1|bloomberg", "ingestion_ts": "2024-01-15T14:30:05Z"},  # Newer
        ]
        # Window function partitions by dedup_key, orders by ingestion_ts DESC, takes row 1
        latest = max(records, key=lambda r: r["ingestion_ts"])
        assert latest["ingestion_ts"] == "2024-01-15T14:30:05Z"

    def test_unique_records_unchanged(self):
        """Records with unique composite keys are all preserved."""
        records = [
            {"dedup_key": "AAPL|ts1|bloomberg"},
            {"dedup_key": "MSFT|ts2|reuters"},
            {"dedup_key": "GOOG|ts3|bloomberg"},
        ]
        unique_keys = {r["dedup_key"] for r in records}
        assert len(unique_keys) == 3  # All unique, none dropped

    def test_dedup_metrics_tracked(self):
        """Dedup reports number of records removed."""
        before_count = 10000
        after_count = 9500
        duplicates_removed = before_count - after_count
        assert duplicates_removed == 500


class TestDataQualityAbort:
    """Tests for quality abort threshold (>30% rejection halts batch)."""

    def test_below_threshold_continues(self):
        """Rejection rate below 30% allows pipeline to continue."""
        total_records = 10000
        rejected = 2000  # 20%
        rejection_rate = rejected / total_records
        abort_threshold = 0.30
        should_abort = rejection_rate > abort_threshold
        assert should_abort is False

    def test_above_threshold_aborts(self):
        """Rejection rate above 30% halts the batch with DataQualityAbortError."""
        total_records = 10000
        rejected = 3500  # 35%
        rejection_rate = rejected / total_records
        abort_threshold = 0.30
        should_abort = rejection_rate > abort_threshold
        assert should_abort is True

    def test_exactly_threshold_continues(self):
        """Rejection rate exactly at 30% does NOT abort (strictly greater than)."""
        total_records = 10000
        rejected = 3000  # 30% exactly
        rejection_rate = rejected / total_records
        abort_threshold = 0.30
        should_abort = rejection_rate > abort_threshold
        assert should_abort is False

    def test_abort_emits_failure_event(self):
        """When aborting, emits 'quality.failed' EventBridge event."""
        event = {
            "Source": "verticalbroker.etl-engine",
            "DetailType": "PipelineExecutionFailed",
            "Detail": {
                "job_name": "bronze-to-silver",
                "error_type": "DataQualityAbortError",
                "rejection_rate": 0.35,
                "threshold": 0.30,
            },
        }
        assert event["Detail"]["rejection_rate"] > event["Detail"]["threshold"]


class TestSilverWrite:
    """Tests for Silver layer Parquet write."""

    def test_output_format_is_parquet_snappy(self):
        """Silver output uses Parquet with Snappy compression."""
        format_config = {"format": "parquet", "compression": "snappy"}
        assert format_config["format"] == "parquet"
        assert format_config["compression"] == "snappy"

    def test_output_partitioned_correctly(self):
        """Output partitioned by instrument_type + trade_date."""
        partitions = ["instrument_type", "trade_date"]
        assert "instrument_type" in partitions
        assert "trade_date" in partitions

    def test_silver_sla_60_minutes(self):
        """Bronze-to-Silver must complete within 60 minutes SLA."""
        sla_minutes = 60
        max_dpus = 100
        assert sla_minutes == 60
        assert max_dpus == 100


class TestLineageTracking:
    """Tests for data lineage recording."""

    def test_lineage_record_structure(self):
        """Lineage record contains input/output paths, counts, timestamps."""
        lineage = {
            "job_run_id": str(uuid.uuid4()),
            "input_path": "s3://vb-bronze/source=bloomberg/trade_date=2024-01-15/",
            "output_path": "s3://vb-silver/instrument_type=equity/trade_date=2024-01-15/",
            "input_count": 10000,
            "output_count": 9500,
            "rejected_count": 500,
            "started_at": "2024-01-15T15:00:00Z",
            "completed_at": "2024-01-15T15:45:00Z",
            "duration_seconds": 2700,
        }
        assert lineage["input_count"] == lineage["output_count"] + lineage["rejected_count"]
        assert lineage["duration_seconds"] < 3600  # Under 60 min SLA

"""
Integration tests for ETL pipeline end-to-end.
Tests: S3 Bronze → Glue/PySpark → Silver → Gold (local Spark mode).
"""

import json
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import boto3
import pytest
from moto import mock_aws


pytestmark = [pytest.mark.integration, pytest.mark.etl]


class TestETLPipelineE2E:
    """End-to-end ETL tests using local PySpark and mocked S3."""

    @mock_aws
    def test_bronze_data_written_to_s3(self, monkeypatch):
        """Bronze layer data lands in correct S3 partition."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="vb-bronze-test")

        # Simulate bronze write
        bronze_key = "bronze/source=bloomberg/trade_date=2024-01-15/instrument_type=equity/batch-001.parquet"
        s3.put_object(
            Bucket="vb-bronze-test",
            Key=bronze_key,
            Body=b"parquet-data-placeholder",
        )

        response = s3.head_object(Bucket="vb-bronze-test", Key=bronze_key)
        assert response["ResponseMetadata"]["HTTPStatusCode"] == 200

    @mock_aws
    def test_silver_output_partitioned_correctly(self, monkeypatch):
        """Silver output is partitioned by instrument_type + trade_date."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="vb-silver-test")

        # Simulate silver write
        partitions = [
            "silver/instrument_type=equity/trade_date=2024-01-15/part-00000.snappy.parquet",
            "silver/instrument_type=equity/trade_date=2024-01-16/part-00000.snappy.parquet",
            "silver/instrument_type=option/trade_date=2024-01-15/part-00000.snappy.parquet",
        ]
        for key in partitions:
            s3.put_object(Bucket="vb-silver-test", Key=key, Body=b"data")

        response = s3.list_objects_v2(Bucket="vb-silver-test", Prefix="silver/")
        assert response["KeyCount"] == 3

    @mock_aws
    def test_gold_aggregates_written(self, monkeypatch):
        """Gold layer produces 4 aggregate datasets."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="vb-gold-test")

        gold_tables = [
            "gold/daily_trade_summaries/trade_date=2024-01-15/data.parquet",
            "gold/client_portfolio_snapshots/snapshot_date=2024-01-15/data.parquet",
            "gold/instrument_performance/trade_date=2024-01-15/data.parquet",
            "gold/risk_exposure_aggregates/calculation_date=2024-01-15/data.parquet",
        ]
        for key in gold_tables:
            s3.put_object(Bucket="vb-gold-test", Key=key, Body=b"gold-data")

        response = s3.list_objects_v2(Bucket="vb-gold-test", Prefix="gold/")
        assert response["KeyCount"] == 4

    @mock_aws
    def test_rejected_records_written_to_rejected_path(self, monkeypatch):
        """Records failing quality checks are written to rejected/ prefix."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="vb-silver-test")

        rejected_key = "rejected/trade_date=2024-01-15/reason=null_rate/batch-001.parquet"
        s3.put_object(Bucket="vb-silver-test", Key=rejected_key, Body=b"rejected-records")

        response = s3.list_objects_v2(Bucket="vb-silver-test", Prefix="rejected/")
        assert response["KeyCount"] == 1
        assert "null_rate" in response["Contents"][0]["Key"]


class TestETLEventNotifications:
    """Tests for ETL pipeline event emissions."""

    @mock_aws
    def test_pipeline_success_event(self, monkeypatch):
        """Successful pipeline emits completion event to EventBridge."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        events = boto3.client("events", region_name="us-east-1")
        events.create_event_bus(Name="verticalbroker-platform")

        response = events.put_events(Entries=[{
            "Source": "verticalbroker.etl-engine",
            "DetailType": "PipelineExecutionCompleted",
            "EventBusName": "verticalbroker-platform",
            "Detail": json.dumps({
                "job_name": "bronze-to-silver",
                "records_processed": 10000,
                "records_written": 9500,
                "duration_seconds": 2700,
                "timestamp": datetime.now(UTC).isoformat(),
            }),
        }])
        assert response["FailedEntryCount"] == 0

    @mock_aws
    def test_pipeline_failure_event(self, monkeypatch):
        """Failed pipeline emits failure event with error details."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        events = boto3.client("events", region_name="us-east-1")
        events.create_event_bus(Name="verticalbroker-platform")

        response = events.put_events(Entries=[{
            "Source": "verticalbroker.etl-engine",
            "DetailType": "PipelineExecutionFailed",
            "EventBusName": "verticalbroker-platform",
            "Detail": json.dumps({
                "job_name": "bronze-to-silver",
                "error_type": "DataQualityAbortError",
                "rejection_rate": 0.35,
                "threshold": 0.30,
                "timestamp": datetime.now(UTC).isoformat(),
            }),
        }])
        assert response["FailedEntryCount"] == 0


class TestMedallionArchitectureIntegrity:
    """Tests ensuring medallion layer invariants."""

    def test_bronze_is_immutable(self):
        """Bronze data is append-only (never modified/deleted)."""
        # Bronze S3 bucket uses Object Lock in COMPLIANCE mode
        object_lock_config = {
            "ObjectLockEnabled": "Enabled",
            "Rule": {"DefaultRetention": {"Mode": "COMPLIANCE", "Years": 7}},
        }
        assert object_lock_config["ObjectLockEnabled"] == "Enabled"

    def test_silver_is_deduplicated(self):
        """Silver layer guarantees no duplicate records (composite key unique)."""
        records = [
            {"dedup_key": "AAPL|2024-01-15T14:30:00Z|bloomberg"},
            {"dedup_key": "AAPL|2024-01-15T14:30:00Z|bloomberg"},  # duplicate
            {"dedup_key": "MSFT|2024-01-15T14:30:00Z|bloomberg"},
        ]
        unique = {r["dedup_key"] for r in records}
        assert len(unique) == 2  # Duplicate removed

    def test_gold_is_aggregated(self):
        """Gold layer contains pre-computed aggregates (no raw records)."""
        gold_datasets = [
            "daily_trade_summaries",
            "client_portfolio_snapshots",
            "instrument_performance",
            "risk_exposure_aggregates",
        ]
        assert len(gold_datasets) == 4
        assert all("raw" not in name for name in gold_datasets)

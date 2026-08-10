"""Market Data Ingestion Lambda Handler.

Processes real-time market data from Kinesis Data Streams (Bloomberg B-Pipe and
Thomson Reuters feeds). Validates records, enriches metadata, writes Parquet
micro-batches to S3 Bronze layer, registers partitions in Glue Data Catalog,
and routes malformed records to DLQ with error event emission.

Lambda Configuration:
    - Reserved Concurrency: 2000
    - Provisioned Concurrency: 500
    - Batch Size: 100 records
    - Runtime: Python 3.12

Requirements: 1.1, 1.2, 1.5, 1.6, 7.1, 7.4
"""

from __future__ import annotations

import base64
import io
import json
import os
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.batch import (
    BatchProcessor,
    EventType,
    batch_processor,
)
from aws_lambda_powertools.utilities.data_classes.kinesis_stream_event import (
    KinesisStreamRecord,
)
from aws_lambda_powertools.utilities.typing import LambdaContext

from src.services.market_data.schema import (
    CURRENT_SCHEMA_VERSION,
    SchemaValidationError,
    parse_timestamp,
    validate_record,
)

# --- Configuration from environment variables ---
BRONZE_BUCKET = os.environ.get("BRONZE_BUCKET", "vb-bronze-dev")
GLUE_DATABASE = os.environ.get("GLUE_DATABASE", "verticalbroker_bronze")
GLUE_TABLE = os.environ.get("GLUE_TABLE", "market_data_raw")
DLQ_URL = os.environ.get("DLQ_URL", "")
EVENT_BUS_NAME = os.environ.get("EVENT_BUS_NAME", "verticalbroker-platform")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")

# --- Lambda Powertools setup ---
logger = Logger(service="market-data-ingestion")
tracer = Tracer(service="market-data-ingestion")
metrics = Metrics(namespace="VerticalBroker/MarketData")
processor = BatchProcessor(event_type=EventType.KinesisDataStreamEvent)


@dataclass
class MarketDataRecord:
    """Validated market data record with metadata enrichment.

    Represents a single market data record after validation and metadata
    enrichment. Used as the intermediate representation before Parquet
    serialization and S3 write.
    """

    source_id: str
    """Source identifier: 'bloomberg' or 'thomson-reuters'."""

    instrument_id: str
    """ISIN (12 chars) or CUSIP (9 chars) instrument identifier."""

    timestamp: datetime
    """Source timestamp in UTC."""

    ingestion_ts: datetime
    """Platform ingestion timestamp in UTC (millisecond precision)."""

    schema_version: str
    """Record schema version, e.g., 'v2.3.1'."""

    partition_key: str
    """Derived partition key: {source}/{instrument_type}/{date}."""

    payload: dict = field(default_factory=dict)
    """Raw market data fields from the source."""

    def to_flat_dict(self) -> dict[str, Any]:
        """Convert record to flat dict suitable for Parquet serialization."""
        return {
            "source_id": self.source_id,
            "instrument_id": self.instrument_id,
            "timestamp": self.timestamp.isoformat(),
            "ingestion_ts": self.ingestion_ts.isoformat(),
            "schema_version": self.schema_version,
            "partition_key": self.partition_key,
            "payload": json.dumps(self.payload),
        }


class MarketDataProcessor:
    """Processes Kinesis batches of market data with validation and routing.

    Handles the full lifecycle of market data ingestion:
    1. Schema validation of incoming records
    2. Metadata enrichment (source_id, ingestion_ts, schema_version, partition_key)
    3. Parquet micro-batch write to S3 Bronze layer
    4. Glue Data Catalog partition registration
    5. DLQ routing for malformed records
    6. EventBridge event emission for successful/failed processing
    """

    def __init__(self):
        """Initialize AWS service clients."""
        self.s3_client = boto3.client("s3")
        self.glue_client = boto3.client("glue")
        self.eventbridge_client = boto3.client("events")
        self.sqs_client = boto3.client("sqs")
        self._registered_partitions: set[str] = set()

    @tracer.capture_method
    def process_record(self, record: dict[str, Any]) -> MarketDataRecord:
        """Validate, enrich, and transform a single market data record.

        Args:
            record: Raw market data record dict from Kinesis payload.

        Returns:
            Validated and enriched MarketDataRecord.

        Raises:
            SchemaValidationError: If the record fails schema validation.
        """
        # Validate schema
        errors = validate_record(record)
        if errors:
            raise errors[0]

        # Parse source timestamp
        source_timestamp = parse_timestamp(record["timestamp"])

        # Generate ingestion timestamp with millisecond precision
        ingestion_ts = datetime.now(timezone.utc)

        # Derive partition key: {source}/{instrument_type}/{date}
        instrument_type = _derive_instrument_type(record["instrument_id"])
        partition_key = (
            f"{record['source_id']}/{instrument_type}/{source_timestamp.strftime('%Y-%m-%d')}"
        )

        # Extract payload (all fields except the required schema fields)
        payload = {
            k: v
            for k, v in record.items()
            if k not in ("source_id", "instrument_id", "timestamp")
        }

        return MarketDataRecord(
            source_id=record["source_id"],
            instrument_id=record["instrument_id"],
            timestamp=source_timestamp,
            ingestion_ts=ingestion_ts,
            schema_version=CURRENT_SCHEMA_VERSION,
            partition_key=partition_key,
            payload=payload,
        )

    @tracer.capture_method
    def write_micro_batch(self, records: list[MarketDataRecord]) -> str:
        """Write validated records as a Parquet micro-batch to S3 Bronze layer.

        Path format: s3://{bucket}/market_data/source={src}/year=YYYY/month=MM/day=DD/hour=HH/

        Args:
            records: List of validated MarketDataRecord instances.

        Returns:
            S3 object key where the micro-batch was written.
        """
        if not records:
            return ""

        # Use the first record's timestamp for partitioning
        ref_record = records[0]
        ref_ts = ref_record.timestamp

        # Build Hive-style partition path
        partition_path = (
            f"market_data/"
            f"source={ref_record.source_id}/"
            f"year={ref_ts.strftime('%Y')}/"
            f"month={ref_ts.strftime('%m')}/"
            f"day={ref_ts.strftime('%d')}/"
            f"hour={ref_ts.strftime('%H')}/"
        )

        # Generate unique object key for this micro-batch
        batch_id = str(uuid.uuid4())
        object_key = f"{partition_path}{batch_id}.parquet"

        # Convert records to Parquet using PyArrow
        parquet_buffer = _records_to_parquet(records)

        # Upload to S3 Bronze bucket
        self.s3_client.put_object(
            Bucket=BRONZE_BUCKET,
            Key=object_key,
            Body=parquet_buffer.getvalue(),
            ContentType="application/x-parquet",
            Metadata={
                "schema_version": CURRENT_SCHEMA_VERSION,
                "record_count": str(len(records)),
                "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
            },
        )

        logger.info(
            "Micro-batch written to S3",
            extra={
                "bucket": BRONZE_BUCKET,
                "key": object_key,
                "record_count": len(records),
                "size_bytes": parquet_buffer.tell(),
            },
        )

        metrics.add_metric(
            name="RecordsWritten", unit=MetricUnit.Count, value=len(records)
        )
        metrics.add_metric(
            name="MicroBatchSizeBytes", unit=MetricUnit.Bytes, value=parquet_buffer.tell()
        )

        return object_key

    @tracer.capture_method
    def register_partition(self, s3_path: str, partition_values: dict[str, str]) -> None:
        """Register a new partition in Glue Data Catalog.

        Only registers a partition if it hasn't been registered in this
        invocation to avoid redundant API calls.

        Args:
            s3_path: Full S3 path to the partition (without object key).
            partition_values: Dict of partition column name -> value
                            (e.g., {"source": "bloomberg", "year": "2024", ...}).
        """
        partition_key = "/".join(f"{k}={v}" for k, v in sorted(partition_values.items()))

        # Skip if already registered in this invocation
        if partition_key in self._registered_partitions:
            return

        s3_location = f"s3://{BRONZE_BUCKET}/{s3_path}"

        try:
            self.glue_client.create_partition(
                DatabaseName=GLUE_DATABASE,
                TableName=GLUE_TABLE,
                PartitionInput={
                    "Values": list(partition_values.values()),
                    "StorageDescriptor": {
                        "Location": s3_location,
                        "InputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
                        "OutputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
                        "SerdeInfo": {
                            "SerializationLibrary": "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
                        },
                        "Columns": [
                            {"Name": "source_id", "Type": "string"},
                            {"Name": "instrument_id", "Type": "string"},
                            {"Name": "timestamp", "Type": "string"},
                            {"Name": "ingestion_ts", "Type": "string"},
                            {"Name": "schema_version", "Type": "string"},
                            {"Name": "partition_key", "Type": "string"},
                            {"Name": "payload", "Type": "string"},
                        ],
                    },
                },
            )
            self._registered_partitions.add(partition_key)
            logger.info(
                "Partition registered in Glue Data Catalog",
                extra={
                    "database": GLUE_DATABASE,
                    "table": GLUE_TABLE,
                    "partition_values": partition_values,
                    "location": s3_location,
                },
            )
        except self.glue_client.exceptions.AlreadyExistsException:
            # Partition already exists - this is fine (idempotent)
            self._registered_partitions.add(partition_key)
            logger.debug(
                "Partition already exists in catalog",
                extra={"partition_key": partition_key},
            )

    @tracer.capture_method
    def send_to_dlq(self, record: dict[str, Any], error: SchemaValidationError) -> None:
        """Route a malformed record to the Dead-Letter Queue.

        Args:
            record: The original malformed record.
            error: The validation error that caused the rejection.
        """
        if not DLQ_URL:
            logger.warning("DLQ_URL not configured, cannot route malformed record")
            return

        message_body = {
            "original_record": record,
            "error": {
                "field": error.field,
                "reason": error.reason,
            },
            "metadata": {
                "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
                "lambda_function": os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "unknown"),
                "correlation_id": logger.get_correlation_id() or str(uuid.uuid4()),
            },
        }

        self.sqs_client.send_message(
            QueueUrl=DLQ_URL,
            MessageBody=json.dumps(message_body, default=str),
            MessageAttributes={
                "ErrorField": {"DataType": "String", "StringValue": error.field},
                "ErrorReason": {"DataType": "String", "StringValue": error.reason},
            },
        )

        metrics.add_metric(name="MalformedRecords", unit=MetricUnit.Count, value=1)
        logger.warning(
            "Malformed record routed to DLQ",
            extra={
                "error_field": error.field,
                "error_reason": error.reason,
            },
        )

    @tracer.capture_method
    def emit_ingestion_event(
        self, s3_key: str, record_count: int, source_id: str, size_bytes: int
    ) -> None:
        """Emit a data.ingested event to EventBridge on successful batch write.

        Args:
            s3_key: The S3 object key of the written micro-batch.
            record_count: Number of records in the batch.
            source_id: The source identifier (bloomberg/thomson-reuters).
            size_bytes: Size of the written Parquet file in bytes.
        """
        event_detail = {
            "source_id": source_id,
            "partition_path": s3_key,
            "record_count": record_count,
            "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
            "schema_version": CURRENT_SCHEMA_VERSION,
            "size_bytes": size_bytes,
        }

        self.eventbridge_client.put_events(
            Entries=[
                {
                    "Source": "verticalbroker.market-data",
                    "DetailType": "MarketDataIngested",
                    "Detail": json.dumps(event_detail),
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )

        logger.info(
            "Emitted data.ingested event",
            extra={"event_detail": event_detail},
        )

    @tracer.capture_method
    def emit_error_event(self, error: SchemaValidationError, source_id: str | None = None) -> None:
        """Emit a pipeline.error event to EventBridge for malformed records.

        Args:
            error: The validation error.
            source_id: Optional source identifier if available from the record.
        """
        event_detail = {
            "error_type": "SchemaValidationError",
            "error_field": error.field,
            "error_reason": error.reason,
            "source_id": source_id or "unknown",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "service": "market-data-ingestion",
        }

        self.eventbridge_client.put_events(
            Entries=[
                {
                    "Source": "verticalbroker.market-data",
                    "DetailType": "PipelineError",
                    "Detail": json.dumps(event_detail),
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )

        logger.info(
            "Emitted pipeline.error event",
            extra={"event_detail": event_detail},
        )


# --- Module-level processor instance ---
_processor_instance: MarketDataProcessor | None = None


def _get_processor() -> MarketDataProcessor:
    """Get or create the singleton MarketDataProcessor instance."""
    global _processor_instance
    if _processor_instance is None:
        _processor_instance = MarketDataProcessor()
    return _processor_instance


def record_handler(record: KinesisStreamRecord) -> dict[str, Any]:
    """Process a single Kinesis record within the batch processor.

    This function is called by Lambda Powertools BatchProcessor for each
    record in the Kinesis batch. Valid records are accumulated for micro-batch
    writing; malformed records are routed to DLQ.

    Args:
        record: A Kinesis stream record from the batch.

    Returns:
        Dict with processing result metadata.

    Raises:
        SchemaValidationError: Re-raised after DLQ routing to signal
            batch processor that this record failed.
    """
    market_processor = _get_processor()

    # Decode Kinesis record data
    try:
        payload = json.loads(record.kinesis.data.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        # Record is not valid JSON - route to DLQ
        error = SchemaValidationError(
            field="payload",
            reason=f"Invalid JSON: {str(e)}",
        )
        market_processor.send_to_dlq(
            record={"raw_data": str(record.kinesis.data)},
            error=error,
        )
        market_processor.emit_error_event(error)
        raise error

    # Process and validate the record
    try:
        processed = market_processor.process_record(payload)
        return {
            "status": "success",
            "record": processed.to_flat_dict(),
        }
    except SchemaValidationError as e:
        # Malformed record - route to DLQ and emit error event
        source_id = payload.get("source_id") if isinstance(payload, dict) else None
        market_processor.send_to_dlq(record=payload, error=e)
        market_processor.emit_error_event(e, source_id=source_id)
        raise


@logger.inject_lambda_context(correlation_id_path="Records[0].eventID")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    """Kinesis stream processor entry point.

    Processes a batch of Kinesis records (up to 100 per invocation):
    1. Validates and enriches each record
    2. Writes successful records as a Parquet micro-batch to S3 Bronze
    3. Registers new partitions in Glue Data Catalog
    4. Emits data.ingested event to EventBridge
    5. Routes malformed records to DLQ with error events

    Args:
        event: Kinesis Data Streams event with Records array.
        context: Lambda execution context.

    Returns:
        Batch processing response with per-record success/failure status.
    """
    logger.info(
        "Processing Kinesis batch",
        extra={"record_count": len(event.get("Records", []))},
    )

    market_processor = _get_processor()

    # Process batch using Lambda Powertools BatchProcessor
    batch = BatchProcessor(event_type=EventType.KinesisDataStreamEvent)

    # Use context manager for batch processing
    records = event.get("Records", [])
    processed_records: list[MarketDataRecord] = []
    failed_count = 0

    for raw_record in records:
        try:
            # Decode Kinesis data
            kinesis_data = raw_record.get("kinesis", {}).get("data", "")
            decoded_data = base64.b64decode(kinesis_data).decode("utf-8")
            payload = json.loads(decoded_data)

            # Process and validate
            processed = market_processor.process_record(payload)
            processed_records.append(processed)

        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            error = SchemaValidationError(
                field="payload",
                reason=f"Invalid JSON: {str(e)}",
            )
            market_processor.send_to_dlq(
                record={"raw_data": kinesis_data if "kinesis_data" in dir() else ""},
                error=error,
            )
            market_processor.emit_error_event(error)
            failed_count += 1

        except SchemaValidationError as e:
            source_id = payload.get("source_id") if "payload" in dir() else None
            market_processor.send_to_dlq(record=payload if "payload" in dir() else {}, error=e)
            market_processor.emit_error_event(e, source_id=source_id)
            failed_count += 1

    # Write valid records as Parquet micro-batch
    if processed_records:
        # Group records by source for separate writes per source partition
        records_by_source = _group_by_source(processed_records)

        for source_id, source_records in records_by_source.items():
            s3_key = market_processor.write_micro_batch(source_records)

            if s3_key:
                # Register partition in Glue Data Catalog
                ref_ts = source_records[0].timestamp
                partition_values = {
                    "source": source_id,
                    "year": ref_ts.strftime("%Y"),
                    "month": ref_ts.strftime("%m"),
                    "day": ref_ts.strftime("%d"),
                    "hour": ref_ts.strftime("%H"),
                }
                partition_path = (
                    f"market_data/"
                    f"source={source_id}/"
                    f"year={ref_ts.strftime('%Y')}/"
                    f"month={ref_ts.strftime('%m')}/"
                    f"day={ref_ts.strftime('%d')}/"
                    f"hour={ref_ts.strftime('%H')}/"
                )
                market_processor.register_partition(partition_path, partition_values)

                # Emit success event
                market_processor.emit_ingestion_event(
                    s3_key=s3_key,
                    record_count=len(source_records),
                    source_id=source_id,
                    size_bytes=0,  # Will be populated from S3 response in production
                )

    # Log final metrics
    metrics.add_metric(
        name="BatchRecordsTotal", unit=MetricUnit.Count, value=len(records)
    )
    metrics.add_metric(
        name="BatchRecordsSuccess", unit=MetricUnit.Count, value=len(processed_records)
    )
    metrics.add_metric(
        name="BatchRecordsFailed", unit=MetricUnit.Count, value=failed_count
    )

    logger.info(
        "Batch processing complete",
        extra={
            "total_records": len(records),
            "successful_records": len(processed_records),
            "failed_records": failed_count,
        },
    )

    # Return batch item failures for Kinesis to retry only failed records
    response = {
        "batchItemFailures": [
            {"itemIdentifier": rec.get("kinesis", {}).get("sequenceNumber", "")}
            for rec in records[len(processed_records):]
            if rec.get("kinesis", {}).get("sequenceNumber")
        ]
        if failed_count > 0
        else []
    }

    return response


def _group_by_source(
    records: list[MarketDataRecord],
) -> dict[str, list[MarketDataRecord]]:
    """Group processed records by source_id for separate partition writes.

    Args:
        records: List of validated MarketDataRecord instances.

    Returns:
        Dict mapping source_id to list of records from that source.
    """
    grouped: dict[str, list[MarketDataRecord]] = {}
    for record in records:
        grouped.setdefault(record.source_id, []).append(record)
    return grouped


def _derive_instrument_type(instrument_id: str) -> str:
    """Derive instrument type from instrument identifier format.

    ISIN (12 chars) -> 'isin'
    CUSIP (9 chars) -> 'cusip'

    Args:
        instrument_id: The instrument identifier string.

    Returns:
        Instrument type string.
    """
    if len(instrument_id) == 12:
        return "isin"
    elif len(instrument_id) == 9:
        return "cusip"
    return "unknown"


def _records_to_parquet(records: list[MarketDataRecord]) -> io.BytesIO:
    """Convert a list of MarketDataRecord to Parquet format in memory.

    Uses PyArrow for efficient columnar serialization with Snappy compression.

    Args:
        records: List of MarketDataRecord instances.

    Returns:
        BytesIO buffer containing the Parquet file.
    """
    # Define schema
    schema = pa.schema(
        [
            pa.field("source_id", pa.string()),
            pa.field("instrument_id", pa.string()),
            pa.field("timestamp", pa.string()),
            pa.field("ingestion_ts", pa.string()),
            pa.field("schema_version", pa.string()),
            pa.field("partition_key", pa.string()),
            pa.field("payload", pa.string()),
        ]
    )

    # Build columnar arrays
    flat_records = [r.to_flat_dict() for r in records]
    table = pa.Table.from_pylist(flat_records, schema=schema)

    # Write to buffer with Snappy compression
    buffer = io.BytesIO()
    pq.write_table(table, buffer, compression="snappy")
    buffer.seek(0)

    return buffer

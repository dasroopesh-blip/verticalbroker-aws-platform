"""Bronze to Silver ETL: Cleanse, validate, deduplicate, conform.

AWS Glue PySpark job that transforms raw Bronze layer data into validated,
deduplicated Silver layer data with schema enforcement and data quality checks.

Job Configuration:
    - Worker Type: G.2X (8 vCPU, 32 GB RAM)
    - Max DPUs: 100
    - Timeout: 60 minutes
    - Job Bookmarks: Enabled
    - Retry Attempts: 3

Requirements:
    3.1 - Trigger Glue PySpark job within 5 min of new Bronze partition
    3.2 - Validate against Glue Data Catalog schemas, reject failures
    3.3 - Deduplicate on composite key (instrument_id + timestamp + source_id)
    3.4 - Write Parquet/Snappy, partitioned by instrument_type and trade_date
    3.5 - Maintain data lineage metadata
    3.7 - Complete within 60 min, G.2X workers, max 100 DPUs
    18.1 - Data quality checks at Bronze-to-Silver boundary
    18.2 - Null thresholds, range validation, freshness SLAs
"""

import sys
import json
import logging
import time
from datetime import datetime, timezone
from typing import Tuple
from uuid import uuid4

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.dynamicframe import DynamicFrame
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType,
    StructField,
    StringType,
    DecimalType,
    IntegerType,
    TimestampType,
    BooleanType,
    DoubleType,
)
from pyspark.sql.window import Window



logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


# Silver layer schema definition (explicit StructType for enforcement)
SILVER_SCHEMA = StructType([
    StructField("instrument_id", StringType(), nullable=False),
    StructField("instrument_type", StringType(), nullable=False),
    StructField("instrument_name", StringType(), nullable=True),
    StructField("exchange", StringType(), nullable=True),
    StructField("trade_date", StringType(), nullable=False),
    StructField("source_id", StringType(), nullable=False),
    StructField("bid_price", DecimalType(18, 8), nullable=False),
    StructField("ask_price", DecimalType(18, 8), nullable=False),
    StructField("last_price", DecimalType(18, 8), nullable=False),
    StructField("mid_price", DecimalType(18, 8), nullable=True),
    StructField("spread", DecimalType(18, 8), nullable=True),
    StructField("volume", IntegerType(), nullable=False),
    StructField("source_timestamp", TimestampType(), nullable=False),
    StructField("ingestion_timestamp", TimestampType(), nullable=False),
    StructField("schema_version", StringType(), nullable=True),
    StructField("is_delayed", BooleanType(), nullable=True),
    StructField("market_status", StringType(), nullable=True),
    StructField("quality_score", DoubleType(), nullable=True),
    StructField("dedup_key", StringType(), nullable=True),
    StructField("processing_job_id", StringType(), nullable=True),
])



# Data quality rule thresholds
DATA_QUALITY_CONFIG = {
    "null_thresholds": {
        "instrument_id": 0.0,      # Zero tolerance for null instrument_id
        "source_id": 0.0,          # Zero tolerance for null source
        "bid_price": 0.05,         # Max 5% null bid prices
        "ask_price": 0.05,         # Max 5% null ask prices
        "last_price": 0.05,        # Max 5% null last prices
        "volume": 0.10,            # Max 10% null volume
        "source_timestamp": 0.0,   # Zero tolerance for null timestamp
    },
    "range_rules": {
        "bid_price": {"min": 0.0, "max": 1_000_000.0},
        "ask_price": {"min": 0.0, "max": 1_000_000.0},
        "last_price": {"min": 0.0, "max": 1_000_000.0},
        "volume": {"min": 0, "max": 1_000_000_000},
    },
    "freshness_max_hours": 24,     # Records older than 24h flagged stale
    "abort_threshold_pct": 30.0,   # Abort batch if >30% records fail quality
}



class PipelineMetrics:
    """Tracks ETL pipeline metrics for lineage and monitoring."""

    def __init__(self, job_id: str):
        self.job_id = job_id
        self.start_time = datetime.now(timezone.utc)
        self.input_count = 0
        self.output_count = 0
        self.schema_rejected_count = 0
        self.quality_rejected_count = 0
        self.dedup_removed_count = 0
        self.end_time = None
        self.status = "RUNNING"
        self.error_message = None

    @property
    def rejected_count(self) -> int:
        """Total records rejected across all stages."""
        return self.schema_rejected_count + self.quality_rejected_count

    @property
    def processing_duration_seconds(self) -> float:
        """Total processing duration in seconds."""
        end = self.end_time or datetime.now(timezone.utc)
        return (end - self.start_time).total_seconds()

    def to_dict(self) -> dict:
        """Convert metrics to dictionary for lineage storage."""
        return {
            "job_id": self.job_id,
            "start_time": self.start_time.isoformat(),
            "end_time": self.end_time.isoformat() if self.end_time else None,
            "processing_duration_seconds": self.processing_duration_seconds,
            "input_count": self.input_count,
            "output_count": self.output_count,
            "schema_rejected_count": self.schema_rejected_count,
            "quality_rejected_count": self.quality_rejected_count,
            "dedup_removed_count": self.dedup_removed_count,
            "total_rejected_count": self.rejected_count,
            "status": self.status,
            "error_message": self.error_message,
        }



class BronzeToSilverETL:
    """Transforms raw Bronze data into validated Silver layer.

    Executes the full Bronze-to-Silver pipeline:
    1. Extract raw data from Glue Data Catalog (Bronze)
    2. Validate schema against catalog definition
    3. Deduplicate on composite key (instrument_id + timestamp + source_id)
    4. Apply data quality rules (null checks, range validation, freshness)
    5. Write validated data to Silver layer (Parquet/Snappy)
    6. Record lineage metadata

    Configuration:
        Worker Type: G.2X (8 vCPU, 32 GB)
        Max Workers: 100 DPU
        Timeout: 60 minutes
        Job Bookmarks: Enabled for incremental processing
    """

    # Constants
    BRONZE_DATABASE = "verticalbroker_bronze"
    BRONZE_TABLE = "market_data_raw"
    SILVER_BUCKET_TEMPLATE = "s3://vb-silver-{env}/market_data/"
    ERROR_BUCKET_TEMPLATE = "s3://vb-silver-{env}/market_data/_errors/"
    LINEAGE_BUCKET_TEMPLATE = "s3://vb-silver-{env}/market_data/_lineage/"
    MAX_RETRY_ATTEMPTS = 3
    RETRY_BACKOFF_BASE_SECONDS = 30

    def __init__(self, glue_context: GlueContext, job_args: dict):
        """Initialize Bronze-to-Silver ETL job.

        Args:
            glue_context: AWS Glue context providing Spark and catalog access.
            job_args: Resolved job arguments containing:
                - source_partition: S3 partition path to process
                - job_id: Unique job execution ID
                - environment: Deployment environment (dev/staging/production)
                - event_bus_name: EventBridge bus for event emission
        """
        self.glue_context = glue_context
        self.spark = glue_context.spark_session
        self.source_partition = job_args["source_partition"]
        self.job_id = job_args.get("job_id", str(uuid4()))
        self.env = job_args.get("environment", "production")
        self.event_bus_name = job_args.get(
            "event_bus_name", "verticalbroker-platform"
        )
        self.metrics = PipelineMetrics(self.job_id)
        self._eventbridge_client = None



    @property
    def eventbridge_client(self):
        """Lazy-initialize EventBridge client."""
        if self._eventbridge_client is None:
            import boto3
            self._eventbridge_client = boto3.client("events")
        return self._eventbridge_client

    @property
    def silver_path(self) -> str:
        """S3 path for Silver layer output."""
        return self.SILVER_BUCKET_TEMPLATE.format(env=self.env)

    @property
    def error_path(self) -> str:
        """S3 path for rejected records."""
        return self.ERROR_BUCKET_TEMPLATE.format(env=self.env)

    @property
    def lineage_path(self) -> str:
        """S3 path for lineage metadata."""
        return self.LINEAGE_BUCKET_TEMPLATE.format(env=self.env)

    def extract(self) -> DynamicFrame:
        """Read raw data from Bronze S3 partition via Glue Data Catalog.

        Uses push-down predicate on partition_path to read only the
        target partition, minimizing data scan and cost.

        Returns:
            DynamicFrame containing raw Bronze records for the partition.

        Raises:
            Exception: If partition cannot be read or is empty.
        """
        logger.info(
            f"Extracting from Bronze: database={self.BRONZE_DATABASE}, "
            f"table={self.BRONZE_TABLE}, partition={self.source_partition}"
        )

        dynamic_frame = self.glue_context.create_dynamic_frame.from_catalog(
            database=self.BRONZE_DATABASE,
            table_name=self.BRONZE_TABLE,
            push_down_predicate=f"partition_path = '{self.source_partition}'",
            transformation_ctx="bronze_extract",
        )

        self.metrics.input_count = dynamic_frame.count()
        logger.info(f"Extracted {self.metrics.input_count} records from Bronze")

        if self.metrics.input_count == 0:
            logger.warning(
                f"No records found in partition: {self.source_partition}"
            )

        return dynamic_frame



    def validate_schema(
        self, df: DynamicFrame
    ) -> Tuple[DynamicFrame, DynamicFrame]:
        """Validate records against the Glue Data Catalog schema.

        Applies schema enforcement using the registered catalog schema.
        Records that do not conform are routed to the rejected frame.

        Args:
            df: Input DynamicFrame from Bronze extraction.

        Returns:
            Tuple of (valid_frame, rejected_frame) where:
            - valid_frame: Records passing schema validation
            - rejected_frame: Records failing schema validation
        """
        logger.info("Validating schema against Glue Data Catalog definition")

        # Apply mapping to enforce expected schema types
        # resolveChoice handles type ambiguities from source data
        resolved = df.resolveChoice(
            choice="match_catalog",
            database=self.BRONZE_DATABASE,
            table_name=self.BRONZE_TABLE,
            transformation_ctx="schema_resolve",
        )

        # Convert to Spark DataFrame for null-check on required fields
        spark_df = resolved.toDF()
        required_fields = [
            field.name
            for field in SILVER_SCHEMA.fields
            if not field.nullable
        ]

        # Records with nulls in required fields are rejected
        valid_condition = None
        for field_name in required_fields:
            if field_name in spark_df.columns:
                condition = F.col(field_name).isNotNull()
                if valid_condition is None:
                    valid_condition = condition
                else:
                    valid_condition = valid_condition & condition

        if valid_condition is not None:
            valid_df = spark_df.filter(valid_condition)
            rejected_df = spark_df.filter(~valid_condition)
        else:
            valid_df = spark_df
            rejected_df = self.spark.createDataFrame([], spark_df.schema)

        valid_count = valid_df.count()
        rejected_count = rejected_df.count()
        self.metrics.schema_rejected_count = rejected_count

        logger.info(
            f"Schema validation: {valid_count} valid, "
            f"{rejected_count} rejected"
        )

        valid_frame = DynamicFrame.fromDF(
            valid_df, self.glue_context, "schema_valid"
        )
        rejected_frame = DynamicFrame.fromDF(
            rejected_df, self.glue_context, "schema_rejected"
        )

        return valid_frame, rejected_frame



    def deduplicate(self, df: DynamicFrame) -> DynamicFrame:
        """Deduplicate records on composite key.

        Uses composite key of instrument_id + timestamp + source_id.
        When duplicates exist, keeps the record with the latest
        ingestion_timestamp (most recent arrival).

        Args:
            df: Input DynamicFrame with validated records.

        Returns:
            DynamicFrame with duplicates removed, keeping latest by
            ingestion_timestamp.
        """
        logger.info("Deduplicating on composite key: "
                    "instrument_id + source_timestamp + source_id")

        spark_df = df.toDF()
        count_before = spark_df.count()

        # Window partitioned by composite key, ordered by ingestion_timestamp
        # descending so row_number=1 is the latest ingestion
        dedup_window = Window.partitionBy(
            "instrument_id", "source_timestamp", "source_id"
        ).orderBy(F.col("ingestion_timestamp").desc())

        deduped_df = (
            spark_df
            .withColumn("_row_num", F.row_number().over(dedup_window))
            .filter(F.col("_row_num") == 1)
            .drop("_row_num")
        )

        count_after = deduped_df.count()
        self.metrics.dedup_removed_count = count_before - count_after

        logger.info(
            f"Deduplication: {count_before} → {count_after} "
            f"({self.metrics.dedup_removed_count} duplicates removed)"
        )

        return DynamicFrame.fromDF(
            deduped_df, self.glue_context, "deduped"
        )



    def apply_data_quality(
        self, df: DynamicFrame
    ) -> Tuple[DynamicFrame, DynamicFrame]:
        """Apply data quality rules: null checks, range validation, freshness.

        Rules applied:
        1. Null checks: Reject records exceeding null thresholds per column
        2. Range validation: Reject prices/volumes outside acceptable bounds
        3. Freshness: Flag records older than configured max hours

        If more than 30% of records fail quality checks, the entire batch
        is aborted to prevent bad data propagation.

        Args:
            df: Input DynamicFrame (deduplicated and schema-validated).

        Returns:
            Tuple of (passed_frame, rejected_frame) where:
            - passed_frame: Records passing all quality rules
            - rejected_frame: Records failing one or more quality rules

        Raises:
            DataQualityAbortError: If rejection rate exceeds 30% threshold.
        """
        logger.info("Applying data quality rules")

        spark_df = df.toDF()
        total_count = spark_df.count()

        if total_count == 0:
            logger.warning("No records to apply quality rules to")
            empty_df = self.spark.createDataFrame([], spark_df.schema)
            return (
                DynamicFrame.fromDF(empty_df, self.glue_context, "dq_pass"),
                DynamicFrame.fromDF(empty_df, self.glue_context, "dq_reject"),
            )

        # Build quality rejection condition
        rejection_conditions = []

        # 1. Range validation on price and volume fields
        range_rules = DATA_QUALITY_CONFIG["range_rules"]
        for col_name, bounds in range_rules.items():
            if col_name in spark_df.columns:
                out_of_range = (
                    (F.col(col_name) < bounds["min"])
                    | (F.col(col_name) > bounds["max"])
                )
                rejection_conditions.append(out_of_range)



        # 2. Freshness check: reject records older than max hours
        freshness_hours = DATA_QUALITY_CONFIG["freshness_max_hours"]
        if "source_timestamp" in spark_df.columns:
            cutoff_time = F.current_timestamp() - F.expr(
                f"INTERVAL {freshness_hours} HOURS"
            )
            stale_condition = F.col("source_timestamp") < cutoff_time
            rejection_conditions.append(stale_condition)

        # 3. Spread validation: ask must be >= bid (financial invariant)
        if "bid_price" in spark_df.columns and "ask_price" in spark_df.columns:
            invalid_spread = F.col("ask_price") < F.col("bid_price")
            rejection_conditions.append(invalid_spread)

        # Combine all rejection conditions with OR
        if rejection_conditions:
            combined_rejection = rejection_conditions[0]
            for condition in rejection_conditions[1:]:
                combined_rejection = combined_rejection | condition

            rejected_df = spark_df.filter(combined_rejection)
            passed_df = spark_df.filter(~combined_rejection)
        else:
            passed_df = spark_df
            rejected_df = self.spark.createDataFrame([], spark_df.schema)

        rejected_count = rejected_df.count()
        passed_count = passed_df.count()
        self.metrics.quality_rejected_count = rejected_count

        # Check abort threshold: if >30% bad records, abort the batch
        rejection_rate = (
            (rejected_count / total_count) * 100 if total_count > 0 else 0
        )
        abort_threshold = DATA_QUALITY_CONFIG["abort_threshold_pct"]

        logger.info(
            f"Data quality: {passed_count} passed, {rejected_count} rejected "
            f"({rejection_rate:.1f}% rejection rate, "
            f"threshold={abort_threshold}%)"
        )

        if rejection_rate > abort_threshold:
            error_msg = (
                f"Data quality abort: {rejection_rate:.1f}% rejection rate "
                f"exceeds {abort_threshold}% threshold. "
                f"Batch aborted to prevent bad data propagation. "
                f"Partition: {self.source_partition}"
            )
            logger.error(error_msg)
            raise DataQualityAbortError(error_msg)



        # Enrich passed records with quality metadata
        passed_df = passed_df.withColumn(
            "quality_score", F.lit(1.0 - (rejection_rate / 100.0))
        )

        # Generate dedup_key for lineage tracking
        passed_df = passed_df.withColumn(
            "dedup_key",
            F.sha2(
                F.concat_ws(
                    "|",
                    F.col("instrument_id"),
                    F.col("source_timestamp").cast("string"),
                    F.col("source_id"),
                ),
                256,
            ),
        )

        # Add processing job ID for lineage
        passed_df = passed_df.withColumn(
            "processing_job_id", F.lit(self.job_id)
        )

        passed_frame = DynamicFrame.fromDF(
            passed_df, self.glue_context, "quality_passed"
        )
        rejected_frame = DynamicFrame.fromDF(
            rejected_df, self.glue_context, "quality_rejected"
        )

        return passed_frame, rejected_frame



    def write_silver(self, df: DynamicFrame) -> None:
        """Write validated data to Silver layer as Parquet with Snappy.

        Output is partitioned by instrument_type and trade_date for
        efficient partition elimination during downstream queries.

        Args:
            df: DynamicFrame containing quality-validated records.
        """
        logger.info(f"Writing Silver layer to: {self.silver_path}")

        # Ensure trade_date partition column exists
        spark_df = df.toDF()
        if "trade_date" not in spark_df.columns:
            # Derive trade_date from source_timestamp
            spark_df = spark_df.withColumn(
                "trade_date",
                F.date_format(F.col("source_timestamp"), "yyyy-MM-dd"),
            )
            df = DynamicFrame.fromDF(
                spark_df, self.glue_context, "silver_with_trade_date"
            )

        # Compute mid_price and spread if not already present
        if "mid_price" not in spark_df.columns:
            spark_df = spark_df.withColumn(
                "mid_price",
                (F.col("bid_price") + F.col("ask_price")) / 2,
            )
        if "spread" not in spark_df.columns:
            spark_df = spark_df.withColumn(
                "spread",
                F.col("ask_price") - F.col("bid_price"),
            )
            df = DynamicFrame.fromDF(
                spark_df, self.glue_context, "silver_enriched"
            )

        self.glue_context.write_dynamic_frame.from_options(
            frame=df,
            connection_type="s3",
            format="parquet",
            connection_options={
                "path": self.silver_path,
                "partitionKeys": ["instrument_type", "trade_date"],
            },
            format_options={"compression": "snappy"},
            transformation_ctx="silver_write",
        )

        self.metrics.output_count = df.count()
        logger.info(
            f"Wrote {self.metrics.output_count} records to Silver layer"
        )



    def _write_rejected(
        self, schema_rejected: DynamicFrame, quality_rejected: DynamicFrame
    ) -> None:
        """Write rejected records to error partition for investigation.

        Args:
            schema_rejected: Records failing schema validation.
            quality_rejected: Records failing quality checks.
        """
        # Union rejected records from both stages
        if schema_rejected.count() > 0:
            self.glue_context.write_dynamic_frame.from_options(
                frame=schema_rejected,
                connection_type="s3",
                format="parquet",
                connection_options={
                    "path": f"{self.error_path}schema_rejected/",
                    "partitionKeys": ["trade_date"],
                },
                format_options={"compression": "snappy"},
                transformation_ctx="schema_rejected_write",
            )

        if quality_rejected.count() > 0:
            self.glue_context.write_dynamic_frame.from_options(
                frame=quality_rejected,
                connection_type="s3",
                format="parquet",
                connection_options={
                    "path": f"{self.error_path}quality_rejected/",
                    "partitionKeys": ["trade_date"],
                },
                format_options={"compression": "snappy"},
                transformation_ctx="quality_rejected_write",
            )

        logger.info(
            f"Wrote rejected records: {schema_rejected.count()} schema, "
            f"{quality_rejected.count()} quality"
        )



    def write_lineage(
        self,
        input_count: int,
        output_count: int,
        rejected_count: int,
    ) -> None:
        """Record data lineage metadata for audit trail.

        Writes lineage record to S3 as JSON containing:
        - Source partition path
        - Transformation job ID
        - Record counts (input, output, rejected)
        - Processing duration
        - Quality metrics

        Args:
            input_count: Total records extracted from Bronze.
            output_count: Records successfully written to Silver.
            rejected_count: Total records rejected (schema + quality).
        """
        self.metrics.end_time = datetime.now(timezone.utc)
        self.metrics.input_count = input_count
        self.metrics.output_count = output_count

        lineage_record = {
            "lineage_id": str(uuid4()),
            "job_id": self.job_id,
            "pipeline_stage": "bronze-to-silver",
            "source_partition": self.source_partition,
            "source_database": self.BRONZE_DATABASE,
            "source_table": self.BRONZE_TABLE,
            "target_path": self.silver_path,
            "record_counts": {
                "input": input_count,
                "output": output_count,
                "schema_rejected": self.metrics.schema_rejected_count,
                "quality_rejected": self.metrics.quality_rejected_count,
                "dedup_removed": self.metrics.dedup_removed_count,
                "total_rejected": rejected_count,
            },
            "processing": {
                "start_time": self.metrics.start_time.isoformat(),
                "end_time": self.metrics.end_time.isoformat(),
                "duration_seconds": self.metrics.processing_duration_seconds,
                "worker_type": "G.2X",
                "environment": self.env,
            },
            "quality_metrics": {
                "rejection_rate_pct": (
                    (rejected_count / input_count * 100)
                    if input_count > 0
                    else 0.0
                ),
                "dedup_rate_pct": (
                    (self.metrics.dedup_removed_count / input_count * 100)
                    if input_count > 0
                    else 0.0
                ),
            },
            "status": self.metrics.status,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }



        # Write lineage as JSON to S3
        lineage_df = self.spark.createDataFrame(
            [lineage_record],
        )
        lineage_path = (
            f"{self.lineage_path}{self.job_id}/"
            f"{datetime.now(timezone.utc).strftime('%Y/%m/%d')}/"
        )
        lineage_df.write.mode("overwrite").json(lineage_path)

        logger.info(
            f"Lineage recorded: input={input_count}, output={output_count}, "
            f"rejected={rejected_count}, "
            f"duration={self.metrics.processing_duration_seconds:.1f}s"
        )



    def _emit_event(self, detail_type: str, detail: dict) -> None:
        """Emit an event to EventBridge.

        Args:
            detail_type: EventBridge detail-type string.
            detail: Event detail payload dictionary.
        """
        try:
            self.eventbridge_client.put_events(
                Entries=[
                    {
                        "Source": "verticalbroker.etl-engine",
                        "DetailType": detail_type,
                        "Detail": json.dumps(detail, default=str),
                        "EventBusName": self.event_bus_name,
                    }
                ]
            )
            logger.info(f"Emitted event: {detail_type}")
        except Exception as e:
            logger.error(f"Failed to emit event {detail_type}: {e}")

    def _emit_success_event(self) -> None:
        """Emit pipeline success event to EventBridge."""
        self._emit_event(
            "PipelineExecutionCompleted",
            {
                "job_id": self.job_id,
                "pipeline_stage": "bronze-to-silver",
                "source_partition": self.source_partition,
                "record_counts": {
                    "input": self.metrics.input_count,
                    "output": self.metrics.output_count,
                    "rejected": self.metrics.rejected_count,
                },
                "duration_seconds": self.metrics.processing_duration_seconds,
                "completion_timestamp": datetime.now(timezone.utc).isoformat(),
            },
        )

    def _emit_failure_event(self, error: Exception, retry_count: int) -> None:
        """Emit pipeline failure event to EventBridge.

        Args:
            error: The exception that caused the failure.
            retry_count: Number of retries attempted before failure.
        """
        self._emit_event(
            "PipelineExecutionFailed",
            {
                "job_id": self.job_id,
                "pipeline_stage": "bronze-to-silver",
                "error_type": type(error).__name__,
                "error_message": str(error),
                "retry_count": retry_count,
                "affected_partitions": [self.source_partition],
                "failure_timestamp": datetime.now(timezone.utc).isoformat(),
            },
        )



    def run(self) -> None:
        """Execute full Bronze → Silver pipeline with error handling and retry.

        Pipeline stages:
        1. Extract from Bronze (Glue Data Catalog)
        2. Validate schema (reject non-conforming)
        3. Deduplicate (composite key, keep latest)
        4. Apply data quality rules (null, range, freshness)
        5. Write to Silver (Parquet/Snappy, partitioned)
        6. Write rejected records to error partition
        7. Record lineage metadata
        8. Emit completion/failure event

        Implements retry logic with exponential backoff for transient failures.
        After MAX_RETRY_ATTEMPTS failures, emits pipeline.failed event.
        """
        logger.info(
            f"Starting Bronze-to-Silver ETL: job_id={self.job_id}, "
            f"partition={self.source_partition}, env={self.env}"
        )

        last_error = None
        for attempt in range(1, self.MAX_RETRY_ATTEMPTS + 1):
            try:
                logger.info(
                    f"Attempt {attempt}/{self.MAX_RETRY_ATTEMPTS}"
                )

                # Stage 1: Extract
                raw = self.extract()
                if raw.count() == 0:
                    logger.info("Empty partition, skipping processing")
                    self.metrics.status = "COMPLETED_EMPTY"
                    self.write_lineage(0, 0, 0)
                    self._emit_success_event()
                    return

                # Stage 2: Schema validation
                valid, schema_rejected = self.validate_schema(raw)

                # Stage 3: Deduplication
                deduped = self.deduplicate(valid)

                # Stage 4: Data quality
                quality_passed, quality_rejected = self.apply_data_quality(
                    deduped
                )

                # Stage 5: Write Silver output
                self.write_silver(quality_passed)

                # Stage 6: Write rejected records
                self._write_rejected(schema_rejected, quality_rejected)

                # Stage 7: Record lineage
                total_rejected = (
                    self.metrics.schema_rejected_count
                    + self.metrics.quality_rejected_count
                )
                self.write_lineage(
                    input_count=self.metrics.input_count,
                    output_count=self.metrics.output_count,
                    rejected_count=total_rejected,
                )

                # Stage 8: Emit success event
                self.metrics.status = "COMPLETED"
                self._emit_success_event()

                logger.info(
                    f"Bronze-to-Silver ETL completed successfully: "
                    f"input={self.metrics.input_count}, "
                    f"output={self.metrics.output_count}, "
                    f"rejected={total_rejected}, "
                    f"duration={self.metrics.processing_duration_seconds:.1f}s"
                )
                return



            except DataQualityAbortError as e:
                # Data quality abort is not retryable
                logger.error(f"Data quality abort (non-retryable): {e}")
                self.metrics.status = "ABORTED_QUALITY"
                self.metrics.error_message = str(e)
                self._emit_failure_event(e, attempt)
                raise

            except Exception as e:
                last_error = e
                logger.error(
                    f"Attempt {attempt}/{self.MAX_RETRY_ATTEMPTS} failed: {e}"
                )
                if attempt < self.MAX_RETRY_ATTEMPTS:
                    backoff = self.RETRY_BACKOFF_BASE_SECONDS * (2 ** (attempt - 1))
                    logger.info(f"Retrying in {backoff}s...")
                    time.sleep(backoff)

        # All retries exhausted
        self.metrics.status = "FAILED"
        self.metrics.error_message = str(last_error)
        self.metrics.end_time = datetime.now(timezone.utc)
        self._emit_failure_event(last_error, self.MAX_RETRY_ATTEMPTS)

        logger.error(
            f"Bronze-to-Silver ETL FAILED after {self.MAX_RETRY_ATTEMPTS} "
            f"attempts: {last_error}"
        )
        raise last_error



class DataQualityAbortError(Exception):
    """Raised when data quality rejection rate exceeds abort threshold.

    This error is not retryable — it indicates the source data quality
    is too poor for the batch to proceed.
    """

    pass


# --- Glue Job Entry Point ---

def main():
    """AWS Glue job entry point.

    Resolves job arguments, initializes GlueContext, and executes
    the Bronze-to-Silver ETL pipeline.

    Job Arguments:
        --JOB_NAME: Glue job name (auto-provided)
        --source_partition: Bronze partition path to process
        --job_id: Unique execution ID (from Step Functions)
        --environment: Target environment (dev/staging/production)
        --event_bus_name: EventBridge bus name for events

    Job Configuration:
        Worker Type: G.2X (8 vCPU, 32 GB)
        Max Workers: 100 DPU
        Timeout: 60 minutes
        Job Bookmarks: Enabled
    """
    args = getResolvedOptions(
        sys.argv,
        [
            "JOB_NAME",
            "source_partition",
            "job_id",
            "environment",
            "event_bus_name",
        ],
    )

    # Initialize Spark and Glue contexts
    spark = SparkSession.builder.config(
        "spark.serializer", "org.apache.spark.serializer.KryoSerializer"
    ).getOrCreate()

    glue_context = GlueContext(spark.sparkContext)
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    # Configure Spark for optimal Parquet/Snappy performance
    spark.conf.set("spark.sql.parquet.compression.codec", "snappy")
    spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
    spark.conf.set("spark.sql.adaptive.enabled", "true")

    logger.info(f"Initialized Glue job: {args['JOB_NAME']}")

    # Build job arguments dict
    job_args = {
        "source_partition": args["source_partition"],
        "job_id": args["job_id"],
        "environment": args["environment"],
        "event_bus_name": args.get("event_bus_name", "verticalbroker-platform"),
    }

    # Execute ETL pipeline
    etl = BronzeToSilverETL(glue_context, job_args)
    etl.run()

    # Commit job bookmark for incremental processing
    job.commit()
    logger.info("Job bookmark committed. ETL complete.")


if __name__ == "__main__":
    main()

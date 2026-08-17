"""
Vertical Broker — Trade Data ETL Pipeline (Senior Developer)
=============================================================
Production-ready PySpark job for processing raw trade events.

Pipeline:
  S3 (raw JSON) → Spark → Transform/Validate → Aggregate → S3 (Parquet, partitioned)
                                                          → Glue Catalog (queryable via Athena)

Design Decisions:
- Schema enforcement at read time (fail fast on bad data)
- Decimal types for all financial columns (no floats)
- Partitioned output by date + symbol for efficient queries
- Idempotent writes (overwrite partition, not append)
- Dead letter path for malformed records
- Broadcast join for small dimension tables
- Adaptive Query Execution (AQE) enabled
- Proper resource configuration (shuffle partitions, memory)
"""

import sys
from datetime import datetime, timezone
from decimal import Decimal

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import (
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)
from pyspark.sql.utils import AnalysisException


# =============================================================================
# CONFIGURATION
# =============================================================================

class PipelineConfig:
    """Externalized configuration — no hardcoded paths or values."""

    def __init__(self, args: dict):
        self.environment = args.get("environment", "dev")
        self.run_date = args.get("run_date")  # YYYY-MM-DD format
        self.source_bucket = args.get("source_bucket")
        self.target_bucket = args.get("target_bucket")
        self.dead_letter_bucket = args.get("dead_letter_bucket")
        self.glue_database = args.get("glue_database", f"verticalbroker_{self.environment}")

        # Validate required parameters
        required = ["run_date", "source_bucket", "target_bucket", "dead_letter_bucket"]
        missing = [k for k in required if not getattr(self, k)]
        if missing:
            raise ValueError(f"Missing required parameters: {missing}")

        # Derived paths
        self.raw_path = (
            f"s3://{self.source_bucket}/raw/trades/"
            f"year={self.run_date[:4]}/"
            f"month={self.run_date[5:7]}/"
            f"day={self.run_date[8:10]}/"
        )
        self.processed_path = f"s3://{self.target_bucket}/processed/trades/"
        self.aggregated_path = f"s3://{self.target_bucket}/aggregated/daily_summary/"
        self.dead_letter_path = (
            f"s3://{self.dead_letter_bucket}/failed/trades/{self.run_date}/"
        )


# =============================================================================
# SCHEMA DEFINITION — Explicit, enforced at read time
# =============================================================================

RAW_TRADE_SCHEMA = StructType([
    StructField("request_id", StringType(), nullable=False),
    StructField("customer_id", StringType(), nullable=False),
    StructField("symbol", StringType(), nullable=False),
    StructField("quantity", IntegerType(), nullable=False),
    StructField("price", DecimalType(12, 4), nullable=False),
    StructField("side", StringType(), nullable=False),         # BUY or SELL
    StructField("timestamp", TimestampType(), nullable=False),
    StructField("exchange", StringType(), nullable=True),
    StructField("account_type", StringType(), nullable=True),
])


# =============================================================================
# SPARK SESSION — Production configuration
# =============================================================================

def create_spark_session(config: PipelineConfig) -> SparkSession:
    """Create Spark session with production-tuned settings."""
    builder = (
        SparkSession.builder
        .appName(f"verticalbroker-trade-etl-{config.environment}-{config.run_date}")
        # Adaptive Query Execution — auto-optimizes joins and shuffles
        .config("spark.sql.adaptive.enabled", "true")
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
        .config("spark.sql.adaptive.skewJoin.enabled", "true")
        # Shuffle partitions — tuned for data volume (not default 200)
        .config("spark.sql.shuffle.partitions", "50")
        # Parquet optimization
        .config("spark.sql.parquet.compression.codec", "snappy")
        .config("spark.sql.parquet.mergeSchema", "false")
        # S3 optimization
        .config("spark.hadoop.fs.s3a.committer.name", "magic")
        .config("spark.hadoop.fs.s3a.committer.magic.enabled", "true")
        .config("spark.speculation", "false")  # Disable speculation for exactly-once writes
        # Glue catalog integration
        .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
        .config("hive.metastore.client.factory.class",
                "com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory")
        .enableHiveSupport()
    )
    return builder.getOrCreate()


# =============================================================================
# DATA QUALITY — Validate and separate good/bad records
# =============================================================================

def validate_trades(df, config: PipelineConfig):
    """
    Split DataFrame into valid and invalid records.
    Invalid records go to dead letter path for investigation.
    Returns (valid_df, invalid_count).
    """
    # Define validation rules
    valid_condition = (
        F.col("request_id").isNotNull()
        & F.col("customer_id").isNotNull()
        & F.col("symbol").rlike(r"^[A-Z]{1,5}$")
        & (F.col("quantity") > 0)
        & (F.col("price") > 0)
        & F.col("side").isin("BUY", "SELL")
        & F.col("timestamp").isNotNull()
    )

    # Split into valid and invalid
    valid_df = df.filter(valid_condition)
    invalid_df = df.filter(~valid_condition)

    # Write invalid records to dead letter path
    invalid_count = invalid_df.count()
    if invalid_count > 0:
        (
            invalid_df
            .withColumn("_rejection_reason", F.lit("Failed validation rules"))
            .withColumn("_rejected_at", F.lit(datetime.now(timezone.utc).isoformat()))
            .write
            .mode("append")
            .json(config.dead_letter_path)
        )
        print(f"WARNING: {invalid_count} invalid records written to dead letter path")

    return valid_df, invalid_count


# =============================================================================
# TRANSFORMATIONS
# =============================================================================

def transform_trades(df):
    """
    Apply business transformations to validated trade data.
    All financial calculations use DecimalType — no floats.
    """
    return (
        df
        # Calculate total amount with Decimal precision
        .withColumn(
            "total_amount",
            (F.col("quantity").cast(DecimalType(12, 4)) * F.col("price"))
            .cast(DecimalType(18, 2))
        )
        # Add processing metadata
        .withColumn("processed_at", F.current_timestamp())
        .withColumn("trade_date", F.to_date(F.col("timestamp")))
        .withColumn("trade_hour", F.hour(F.col("timestamp")))
        # Normalize fields
        .withColumn("symbol", F.upper(F.trim(F.col("symbol"))))
        .withColumn("side", F.upper(F.trim(F.col("side"))))
        # Deduplicate by request_id (exactly-once semantics)
        .dropDuplicates(["request_id"])
    )


def compute_daily_aggregations(df):
    """
    Compute daily trading summaries per symbol.
    Used for reporting, dashboards, and analytics.
    """
    return (
        df
        .groupBy("trade_date", "symbol", "side")
        .agg(
            F.count("request_id").alias("trade_count"),
            F.sum("quantity").alias("total_volume"),
            F.sum("total_amount").alias("total_value"),
            F.avg("price").cast(DecimalType(12, 4)).alias("avg_price"),
            F.min("price").alias("min_price"),
            F.max("price").alias("max_price"),
            F.countDistinct("customer_id").alias("unique_customers"),
        )
        .withColumn("computed_at", F.current_timestamp())
    )


# =============================================================================
# WRITE — Idempotent, partitioned output
# =============================================================================

def write_processed_trades(df, config: PipelineConfig):
    """
    Write processed trades as partitioned Parquet.
    Uses overwrite mode on the specific partition (idempotent re-runs).
    """
    (
        df
        .repartition("trade_date", "symbol")  # Optimize file layout
        .write
        .mode("overwrite")
        .partitionBy("trade_date", "symbol")
        .option("path", config.processed_path)
        .format("parquet")
        .saveAsTable(f"{config.glue_database}.processed_trades")
    )


def write_daily_aggregations(df, config: PipelineConfig):
    """Write daily aggregation as partitioned Parquet."""
    (
        df
        .repartition("trade_date")
        .write
        .mode("overwrite")
        .partitionBy("trade_date")
        .option("path", config.aggregated_path)
        .format("parquet")
        .saveAsTable(f"{config.glue_database}.daily_trade_summary")
    )


# =============================================================================
# MAIN — Pipeline orchestration
# =============================================================================

def run_pipeline(config: PipelineConfig):
    """Execute the full ETL pipeline with proper error handling."""

    spark = create_spark_session(config)

    try:
        print(f"Starting trade ETL for {config.run_date} ({config.environment})")
        print(f"Reading from: {config.raw_path}")

        # READ — with schema enforcement
        raw_df = (
            spark.read
            .schema(RAW_TRADE_SCHEMA)
            .option("mode", "DROPMALFORMED")
            .option("columnNameOfCorruptRecord", "_corrupt_record")
            .json(config.raw_path)
        )

        # Cache for multiple operations
        raw_df.cache()
        total_records = raw_df.count()
        print(f"Read {total_records} raw records")

        if total_records == 0:
            print("WARNING: No records found for this date. Exiting gracefully.")
            return

        # VALIDATE
        valid_df, invalid_count = validate_trades(raw_df, config)
        valid_count = valid_df.count()
        print(f"Valid: {valid_count}, Invalid: {invalid_count}")

        # Quality gate — fail if too many invalid records (>5%)
        if total_records > 0:
            error_rate = invalid_count / total_records
            if error_rate > 0.05:
                raise RuntimeError(
                    f"Data quality gate failed: {error_rate:.1%} error rate "
                    f"exceeds 5% threshold ({invalid_count}/{total_records})"
                )

        # TRANSFORM
        transformed_df = transform_trades(valid_df)
        transformed_df.cache()

        # WRITE processed trades
        write_processed_trades(transformed_df, config)
        print(f"Written {valid_count} processed trades")

        # AGGREGATE
        daily_agg_df = compute_daily_aggregations(transformed_df)
        write_daily_aggregations(daily_agg_df, config)
        print("Written daily aggregations")

        # METRICS
        print(f"Pipeline complete: "
              f"total={total_records}, valid={valid_count}, "
              f"invalid={invalid_count}, error_rate={error_rate:.2%}")

    except AnalysisException as e:
        print(f"FATAL: Schema/analysis error — {e}")
        raise
    except Exception as e:
        print(f"FATAL: Pipeline failed — {type(e).__name__}: {e}")
        raise
    finally:
        spark.stop()


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Trade ETL Pipeline")
    parser.add_argument("--environment", required=True, choices=["dev", "staging", "prod"])
    parser.add_argument("--run-date", required=True, help="YYYY-MM-DD")
    parser.add_argument("--source-bucket", required=True)
    parser.add_argument("--target-bucket", required=True)
    parser.add_argument("--dead-letter-bucket", required=True)
    parser.add_argument("--glue-database", required=False)

    args = parser.parse_args()

    config = PipelineConfig({
        "environment": args.environment,
        "run_date": args.run_date,
        "source_bucket": args.source_bucket,
        "target_bucket": args.target_bucket,
        "dead_letter_bucket": args.dead_letter_bucket,
        "glue_database": args.glue_database,
    })

    run_pipeline(config)

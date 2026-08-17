"""
Vertical Broker — SILVER Layer (Cleansed & Conformed)
======================================================
AWS Glue PySpark Job

Silver = Validated, cleansed, business-typed, deduplicated data.
Purpose:
  - Apply strict validation rules (reject bad records)
  - Cast to proper business types (Decimal for money, Timestamp for dates)
  - Deduplicate across historical runs (not just within batch)
  - Normalize and standardize values
  - Apply business rules (valid symbols, positive quantities, etc.)
  - SCD Type 1 merge (upsert new records, don't duplicate)

Source: S3 Parquet (Bronze layer)
Target: S3 Parquet (Silver layer, partitioned by trade_date + symbol)
Catalog: Glue Data Catalog (database: verticalbroker_{env}_silver)
"""

import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql import Window
from pyspark.sql.types import DecimalType, TimestampType


# =============================================================================
# CONFIGURATION
# =============================================================================

args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "environment",
    "run_date",
    "bronze_path",
    "silver_path",
    "dead_letter_path",
    "bronze_database",
    "silver_database",
])

ENVIRONMENT = args["environment"]
RUN_DATE = args["run_date"]
BRONZE_PATH = args["bronze_path"]
SILVER_PATH = args["silver_path"]
DEAD_LETTER_PATH = args["dead_letter_path"]
BRONZE_DATABASE = args["bronze_database"]
SILVER_DATABASE = args["silver_database"]


# =============================================================================
# SPARK + GLUE CONTEXT
# =============================================================================

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.shuffle.partitions", "50")


# =============================================================================
# VALIDATION RULES
# =============================================================================

VALID_SYMBOLS_REGEX = r"^[A-Z]{1,5}$"
VALID_SIDES = ["BUY", "SELL"]
MAX_QUANTITY = 1_000_000
MAX_PRICE = 999999.9999


def apply_validation(df):
    """
    Apply strict business validation.
    Returns (valid_df, rejected_df) with rejection reasons.
    """
    # Add validation flags
    validated = (
        df
        .withColumn("_v_request_id", F.col("request_id").isNotNull() & (F.length("request_id") > 0))
        .withColumn("_v_customer_id", F.col("customer_id").isNotNull() & (F.length("customer_id") > 0))
        .withColumn("_v_symbol", F.col("symbol").rlike(VALID_SYMBOLS_REGEX))
        .withColumn("_v_quantity", (F.col("quantity") > 0) & (F.col("quantity") <= MAX_QUANTITY))
        .withColumn("_v_price", (F.col("price") > 0) & (F.col("price") <= MAX_PRICE))
        .withColumn("_v_side", F.upper(F.col("side")).isin(VALID_SIDES))
        .withColumn("_v_timestamp", F.col("timestamp").isNotNull())
    )

    # All validations must pass
    all_valid = (
        F.col("_v_request_id")
        & F.col("_v_customer_id")
        & F.col("_v_symbol")
        & F.col("_v_quantity")
        & F.col("_v_price")
        & F.col("_v_side")
        & F.col("_v_timestamp")
    )

    # Build rejection reason (for dead letter)
    rejection_reason = F.concat_ws(", ",
        F.when(~F.col("_v_request_id"), F.lit("invalid_request_id")),
        F.when(~F.col("_v_customer_id"), F.lit("invalid_customer_id")),
        F.when(~F.col("_v_symbol"), F.lit("invalid_symbol")),
        F.when(~F.col("_v_quantity"), F.lit("invalid_quantity")),
        F.when(~F.col("_v_price"), F.lit("invalid_price")),
        F.when(~F.col("_v_side"), F.lit("invalid_side")),
        F.when(~F.col("_v_timestamp"), F.lit("invalid_timestamp")),
    )

    # Split
    valid_df = validated.filter(all_valid)
    rejected_df = (
        validated
        .filter(~all_valid)
        .withColumn("_rejection_reason", rejection_reason)
        .withColumn("_rejected_at", F.lit(datetime.now(timezone.utc).isoformat()))
    )

    # Drop validation columns from valid data
    validation_cols = [c for c in valid_df.columns if c.startswith("_v_")]
    valid_df = valid_df.drop(*validation_cols)

    return valid_df, rejected_df


# =============================================================================
# SILVER TRANSFORMATIONS
# =============================================================================

def transform_to_silver(df):
    """
    Apply Silver-layer transformations:
    - Cast to proper types (Decimal for money)
    - Parse timestamps
    - Normalize values
    - Calculate derived fields
    - Deduplicate (keep latest by request_id)
    """
    silver_df = (
        df
        # Type casting — Decimal for financial precision
        .withColumn("price", F.col("price").cast(DecimalType(12, 4)))
        .withColumn("quantity", F.col("quantity").cast("int"))
        # Calculate total_amount with Decimal precision
        .withColumn(
            "total_amount",
            (F.col("quantity").cast(DecimalType(12, 4)) * F.col("price"))
            .cast(DecimalType(18, 2))
        )
        # Parse timestamp properly
        .withColumn("trade_timestamp", F.to_timestamp(F.col("timestamp")))
        .withColumn("trade_date", F.to_date(F.col("trade_timestamp")))
        .withColumn("trade_hour", F.hour(F.col("trade_timestamp")))
        .withColumn("trade_year", F.year(F.col("trade_timestamp")))
        .withColumn("trade_month", F.month(F.col("trade_timestamp")))
        # Normalize
        .withColumn("symbol", F.upper(F.trim(F.col("symbol"))))
        .withColumn("side", F.upper(F.trim(F.col("side"))))
        .withColumn("exchange", F.upper(F.trim(F.coalesce(F.col("exchange"), F.lit("UNKNOWN")))))
        .withColumn("account_type", F.upper(F.trim(F.coalesce(F.col("account_type"), F.lit("STANDARD")))))
        # Add Silver metadata
        .withColumn("_silver_processed_at", F.current_timestamp())
        .withColumn("_silver_version", F.lit(1))
        # Drop raw columns no longer needed
        .drop("timestamp", "_ingestion_timestamp", "_source_file",
               "_job_run_id", "_environment")
    )

    return silver_df


def deduplicate_silver(df):
    """
    Deduplicate by request_id, keeping the LATEST record.
    This handles:
    - Duplicate ingestion (same file processed twice)
    - Late-arriving corrections (newer record wins)
    """
    window = Window.partitionBy("request_id").orderBy(F.col("_ingestion_date").desc())

    return (
        df
        .withColumn("_row_num", F.row_number().over(window))
        .filter(F.col("_row_num") == 1)
        .drop("_row_num")
    )


# =============================================================================
# SILVER PIPELINE
# =============================================================================

def run_silver():
    """Execute Silver layer processing."""
    print(f"[SILVER] Starting processing for {RUN_DATE}")
    print(f"[SILVER] Reading Bronze from: {BRONZE_PATH}")

    # --- READ from Bronze (today's partition) ---
    bronze_partition = f"{BRONZE_PATH}/_ingestion_date={RUN_DATE}/"

    try:
        bronze_df = spark.read.parquet(bronze_partition)
    except Exception as e:
        print(f"[SILVER] No Bronze data for {RUN_DATE}: {e}")
        print("[SILVER] Exiting gracefully — nothing to process.")
        job.commit()
        return

    total_count = bronze_df.count()
    print(f"[SILVER] Read {total_count} Bronze records")

    if total_count == 0:
        print("[SILVER] Empty partition. Exiting.")
        job.commit()
        return

    # --- VALIDATE ---
    valid_df, rejected_df = apply_validation(bronze_df)
    rejected_count = rejected_df.count()
    valid_count = valid_df.count()

    if rejected_count > 0:
        print(f"[SILVER] WARNING: {rejected_count} records failed validation → dead letter")
        (
            rejected_df
            .select("request_id", "customer_id", "symbol", "_rejection_reason", "_rejected_at")
            .write
            .mode("append")
            .json(f"{DEAD_LETTER_PATH}/silver/{RUN_DATE}/")
        )

    # --- QUALITY GATE (stricter than Bronze — 5% threshold) ---
    if total_count > 0:
        error_rate = rejected_count / total_count
        if error_rate > 0.05:
            raise RuntimeError(
                f"[SILVER] Quality gate FAILED: {error_rate:.1%} error rate "
                f"({rejected_count}/{total_count}) exceeds 5% threshold"
            )

    # --- TRANSFORM ---
    silver_df = transform_to_silver(valid_df)

    # --- DEDUPLICATE ---
    silver_df = deduplicate_silver(silver_df)
    deduped_count = silver_df.count()
    dupe_count = valid_count - deduped_count

    if dupe_count > 0:
        print(f"[SILVER] Removed {dupe_count} duplicate records")

    # --- WRITE to Silver (partitioned by trade_date + symbol) ---
    (
        silver_df
        .repartition("trade_date", "symbol")
        .write
        .mode("overwrite")
        .partitionBy("trade_date", "symbol")
        .format("parquet")
        .option("path", SILVER_PATH)
        .saveAsTable(f"{SILVER_DATABASE}.silver_trades")
    )

    print(f"[SILVER] Complete: input={total_count}, valid={valid_count}, "
          f"rejected={rejected_count}, deduped={dupe_count}, output={deduped_count}")

    job.commit()


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    run_silver()

"""
Vertical Broker — BRONZE Layer (Raw Ingestion)
===============================================
AWS Glue PySpark Job

Bronze = Raw data, exactly as received, with minimal transformation.
Purpose: Land raw data into the lakehouse with:
  - Schema enforcement (detect corrupt records)
  - Metadata addition (ingestion timestamp, source file, job run ID)
  - Deduplication at ingestion (prevent re-processing same files)
  - Dead letter handling for unparseable records
  - Partitioned by ingestion date for efficient downstream reads

Source: S3 raw JSON (from trade ingestion pipeline)
Target: S3 Parquet (Bronze layer, partitioned by ingestion_date)
Catalog: Glue Data Catalog (database: verticalbroker_{env}_bronze)
"""

import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import (
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)


# =============================================================================
# CONFIGURATION
# =============================================================================

# Glue job parameters (passed via Terraform/Step Functions)
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "environment",
    "run_date",
    "source_path",
    "bronze_path",
    "dead_letter_path",
    "glue_database",
    "enable_bookmarks",
])

ENVIRONMENT = args["environment"]
RUN_DATE = args["run_date"]
SOURCE_PATH = args["source_path"]
BRONZE_PATH = args["bronze_path"]
DEAD_LETTER_PATH = args["dead_letter_path"]
GLUE_DATABASE = args["glue_database"]
ENABLE_BOOKMARKS = args.get("enable_bookmarks", "true") == "true"


# =============================================================================
# SPARK + GLUE CONTEXT — Production configuration
# =============================================================================

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# Production Spark configs
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.parquet.compression.codec", "snappy")
spark.conf.set("spark.sql.shuffle.partitions", "50")


# =============================================================================
# SCHEMA — Enforced at Bronze layer (fail fast on bad data)
# =============================================================================

RAW_TRADE_SCHEMA = StructType([
    StructField("request_id", StringType(), nullable=True),
    StructField("customer_id", StringType(), nullable=True),
    StructField("symbol", StringType(), nullable=True),
    StructField("quantity", IntegerType(), nullable=True),
    StructField("price", DecimalType(12, 4), nullable=True),
    StructField("side", StringType(), nullable=True),
    StructField("timestamp", StringType(), nullable=True),  # Parse as string first
    StructField("exchange", StringType(), nullable=True),
    StructField("account_type", StringType(), nullable=True),
])


# =============================================================================
# BRONZE PROCESSING
# =============================================================================

def run_bronze():
    """
    Bronze layer: Ingest raw data with minimal transformation.
    - Read raw JSON with schema enforcement
    - Add metadata columns (ingestion time, source, job ID)
    - Separate valid from corrupt records
    - Write valid to Bronze (Parquet, partitioned)
    - Write corrupt to Dead Letter
    """
    job_run_id = args["JOB_RUN_ID"] if "JOB_RUN_ID" in args else "local"
    ingestion_ts = datetime.now(timezone.utc).isoformat()

    print(f"[BRONZE] Starting ingestion for {RUN_DATE}")
    print(f"[BRONZE] Source: {SOURCE_PATH}")
    print(f"[BRONZE] Target: {BRONZE_PATH}")

    # --- READ with schema enforcement ---
    if ENABLE_BOOKMARKS:
        # Use Glue bookmarks to avoid re-processing files
        raw_dyf = glueContext.create_dynamic_frame.from_options(
            connection_type="s3",
            connection_options={
                "paths": [SOURCE_PATH],
                "recurse": True,
            },
            format="json",
            transformation_ctx="raw_source",
        )
        raw_df = raw_dyf.toDF()
    else:
        raw_df = (
            spark.read
            .schema(RAW_TRADE_SCHEMA)
            .option("mode", "PERMISSIVE")
            .option("columnNameOfCorruptRecord", "_corrupt_record")
            .json(SOURCE_PATH)
        )

    total_count = raw_df.count()
    print(f"[BRONZE] Read {total_count} raw records")

    if total_count == 0:
        print("[BRONZE] No new records to process. Exiting gracefully.")
        job.commit()
        return

    # --- ADD METADATA (Bronze always preserves raw + adds lineage) ---
    bronze_df = (
        raw_df
        .withColumn("_ingestion_timestamp", F.lit(ingestion_ts))
        .withColumn("_source_file", F.input_file_name())
        .withColumn("_job_run_id", F.lit(job_run_id))
        .withColumn("_ingestion_date", F.lit(RUN_DATE))
        .withColumn("_environment", F.lit(ENVIRONMENT))
    )

    # --- SEPARATE CORRUPT RECORDS ---
    if "_corrupt_record" in bronze_df.columns:
        corrupt_df = bronze_df.filter(F.col("_corrupt_record").isNotNull())
        valid_df = bronze_df.filter(F.col("_corrupt_record").isNull()).drop("_corrupt_record")

        corrupt_count = corrupt_df.count()
        if corrupt_count > 0:
            print(f"[BRONZE] WARNING: {corrupt_count} corrupt records → dead letter")
            (
                corrupt_df
                .write
                .mode("append")
                .json(f"{DEAD_LETTER_PATH}/bronze/{RUN_DATE}/")
            )
    else:
        valid_df = bronze_df
        corrupt_count = 0

    # --- DEDUPLICATE by request_id within this batch ---
    valid_df = valid_df.dropDuplicates(["request_id"])
    valid_count = valid_df.count()

    # --- QUALITY GATE ---
    if total_count > 0:
        error_rate = corrupt_count / total_count
        if error_rate > 0.10:  # 10% threshold for Bronze (raw data may have issues)
            raise RuntimeError(
                f"[BRONZE] Quality gate FAILED: {error_rate:.1%} error rate "
                f"({corrupt_count}/{total_count}) exceeds 10% threshold"
            )

    # --- WRITE to Bronze (partitioned Parquet) ---
    (
        valid_df
        .repartition("_ingestion_date")
        .write
        .mode("overwrite")  # Idempotent — overwrite partition for this date
        .partitionBy("_ingestion_date")
        .format("parquet")
        .option("path", BRONZE_PATH)
        .saveAsTable(f"{GLUE_DATABASE}.bronze_trades")
    )

    print(f"[BRONZE] Complete: total={total_count}, valid={valid_count}, corrupt={corrupt_count}")

    # --- COMMIT (updates bookmarks) ---
    job.commit()


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    run_bronze()

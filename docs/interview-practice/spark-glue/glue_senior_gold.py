"""
Vertical Broker — GOLD Layer (Business Aggregations)
=====================================================
AWS Glue PySpark Job

Gold = Business-ready aggregations and metrics optimized for consumption.
Purpose:
  - Pre-computed aggregations (no heavy queries at read time)
  - Business KPIs (daily volume, revenue, customer metrics)
  - Dimensional modeling (facts + dimensions)
  - Optimized for Athena/QuickSight/Redshift Spectrum queries
  - SLA: Data available within 1 hour of market close

Source: S3 Parquet (Silver layer)
Target: S3 Parquet (Gold layer, multiple tables)
Catalog: Glue Data Catalog (database: verticalbroker_{env}_gold)

Gold Tables:
  - gold_daily_trading_summary (per symbol per day)
  - gold_customer_activity (per customer per day)
  - gold_exchange_volume (per exchange per day)
  - gold_hourly_patterns (per symbol per hour — intraday analytics)
"""

import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql import Window
from pyspark.sql.types import DecimalType


# =============================================================================
# CONFIGURATION
# =============================================================================

args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "environment",
    "run_date",
    "silver_path",
    "gold_path",
    "silver_database",
    "gold_database",
])

ENVIRONMENT = args["environment"]
RUN_DATE = args["run_date"]
SILVER_PATH = args["silver_path"]
GOLD_PATH = args["gold_path"]
SILVER_DATABASE = args["silver_database"]
GOLD_DATABASE = args["gold_database"]


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
spark.conf.set("spark.sql.shuffle.partitions", "30")  # Gold has smaller output


# =============================================================================
# GOLD AGGREGATIONS
# =============================================================================

def compute_daily_trading_summary(silver_df):
    """
    Gold Table 1: Daily Trading Summary
    One row per symbol per side per day.
    Used for: Executive dashboards, regulatory reporting, P&L.
    """
    return (
        silver_df
        .groupBy("trade_date", "symbol", "side", "exchange")
        .agg(
            F.count("request_id").alias("trade_count"),
            F.sum("quantity").alias("total_volume"),
            F.sum("total_amount").cast(DecimalType(22, 2)).alias("total_value"),
            F.avg("price").cast(DecimalType(12, 4)).alias("avg_price"),
            F.min("price").cast(DecimalType(12, 4)).alias("min_price"),
            F.max("price").cast(DecimalType(12, 4)).alias("max_price"),
            F.stddev("price").cast(DecimalType(12, 4)).alias("price_stddev"),
            F.countDistinct("customer_id").alias("unique_customers"),
            F.min("trade_timestamp").alias("first_trade_time"),
            F.max("trade_timestamp").alias("last_trade_time"),
        )
        .withColumn("vwap",  # Volume-Weighted Average Price
            (F.col("total_value") / F.col("total_volume")).cast(DecimalType(12, 4))
        )
        .withColumn("_computed_at", F.current_timestamp())
        .withColumn("_gold_version", F.lit(1))
    )


def compute_customer_activity(silver_df):
    """
    Gold Table 2: Customer Activity Summary
    One row per customer per day.
    Used for: Customer analytics, risk monitoring, compliance reporting.

    NOTE: This table contains customer_id (PII) — access must be restricted
    via Lake Formation / IAM policies.
    """
    return (
        silver_df
        .groupBy("trade_date", "customer_id", "account_type")
        .agg(
            F.count("request_id").alias("trade_count"),
            F.sum("total_amount").cast(DecimalType(22, 2)).alias("total_value"),
            F.sum(F.when(F.col("side") == "BUY", F.col("total_amount")).otherwise(0))
                .cast(DecimalType(22, 2)).alias("buy_value"),
            F.sum(F.when(F.col("side") == "SELL", F.col("total_amount")).otherwise(0))
                .cast(DecimalType(22, 2)).alias("sell_value"),
            F.countDistinct("symbol").alias("symbols_traded"),
            F.collect_set("symbol").alias("symbols_list"),
            F.min("trade_timestamp").alias("first_trade"),
            F.max("trade_timestamp").alias("last_trade"),
        )
        .withColumn("net_value",
            (F.col("buy_value") - F.col("sell_value")).cast(DecimalType(22, 2))
        )
        .withColumn("_computed_at", F.current_timestamp())
    )


def compute_exchange_volume(silver_df):
    """
    Gold Table 3: Exchange Volume
    One row per exchange per symbol per day.
    Used for: Exchange fee reconciliation, routing optimization.
    """
    return (
        silver_df
        .groupBy("trade_date", "exchange", "symbol")
        .agg(
            F.count("request_id").alias("trade_count"),
            F.sum("quantity").alias("total_volume"),
            F.sum("total_amount").cast(DecimalType(22, 2)).alias("total_value"),
        )
        .withColumn("_computed_at", F.current_timestamp())
    )


def compute_hourly_patterns(silver_df):
    """
    Gold Table 4: Hourly Trading Patterns
    One row per symbol per hour.
    Used for: Intraday analytics, optimal execution timing, market microstructure.
    """
    return (
        silver_df
        .groupBy("trade_date", "trade_hour", "symbol")
        .agg(
            F.count("request_id").alias("trade_count"),
            F.sum("quantity").alias("volume"),
            F.sum("total_amount").cast(DecimalType(22, 2)).alias("value"),
            F.avg("price").cast(DecimalType(12, 4)).alias("avg_price"),
            F.countDistinct("customer_id").alias("active_customers"),
        )
        .withColumn("_computed_at", F.current_timestamp())
    )


# =============================================================================
# WRITE UTILITIES
# =============================================================================

def write_gold_table(df, table_name: str, partition_cols: list):
    """Write a Gold table — idempotent (overwrite partition)."""
    output_path = f"{GOLD_PATH}/{table_name}/"

    (
        df
        .repartition(*[F.col(c) for c in partition_cols])
        .write
        .mode("overwrite")
        .partitionBy(*partition_cols)
        .format("parquet")
        .option("path", output_path)
        .saveAsTable(f"{GOLD_DATABASE}.{table_name}")
    )

    row_count = df.count()
    print(f"[GOLD] Written {table_name}: {row_count} rows")
    return row_count


# =============================================================================
# GOLD PIPELINE
# =============================================================================

def run_gold():
    """Execute Gold layer aggregations."""
    print(f"[GOLD] Starting aggregations for {RUN_DATE}")

    # --- READ from Silver (today's partition) ---
    silver_partition = f"{SILVER_PATH}/trade_date={RUN_DATE}/"

    try:
        silver_df = spark.read.parquet(silver_partition)
    except Exception as e:
        # Try reading from the full Silver path with filter (in case partition path differs)
        print(f"[GOLD] Direct partition read failed, trying filter: {e}")
        try:
            silver_df = (
                spark.read.parquet(SILVER_PATH)
                .filter(F.col("trade_date") == RUN_DATE)
            )
        except Exception as e2:
            print(f"[GOLD] No Silver data available for {RUN_DATE}: {e2}")
            print("[GOLD] Exiting gracefully.")
            job.commit()
            return

    # Cache Silver data (used by all aggregations)
    silver_df.cache()
    total_count = silver_df.count()
    print(f"[GOLD] Read {total_count} Silver records for {RUN_DATE}")

    if total_count == 0:
        print("[GOLD] No data to aggregate. Exiting.")
        job.commit()
        return

    # --- COMPUTE all Gold tables ---
    print("[GOLD] Computing daily trading summary...")
    daily_summary = compute_daily_trading_summary(silver_df)
    write_gold_table(daily_summary, "gold_daily_trading_summary", ["trade_date"])

    print("[GOLD] Computing customer activity...")
    customer_activity = compute_customer_activity(silver_df)
    write_gold_table(customer_activity, "gold_customer_activity", ["trade_date"])

    print("[GOLD] Computing exchange volume...")
    exchange_volume = compute_exchange_volume(silver_df)
    write_gold_table(exchange_volume, "gold_exchange_volume", ["trade_date"])

    print("[GOLD] Computing hourly patterns...")
    hourly_patterns = compute_hourly_patterns(silver_df)
    write_gold_table(hourly_patterns, "gold_hourly_patterns", ["trade_date"])

    # --- UNPERSIST cached data ---
    silver_df.unpersist()

    print(f"[GOLD] All aggregations complete for {RUN_DATE}. Input records: {total_count}")

    job.commit()


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    run_gold()

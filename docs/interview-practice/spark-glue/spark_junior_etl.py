"""
Vertical Broker — Trade Data ETL Pipeline (Junior Developer Submission)
========================================================================
This PySpark job processes raw trade events from S3.
Contains multiple production-critical errors for peer review practice.
"""

from pyspark.sql import SparkSession
from pyspark.sql import functions as F


# ERROR 1 (P1): No schema enforcement — reads with inferred schema
# ERROR 2 (P2): Hardcoded paths — no parameterization
# ERROR 3 (P0): No input validation on configuration

spark = SparkSession.builder.appName("trade_etl").getOrCreate()

# ERROR 4 (P1): Hardcoded production paths in code
INPUT_PATH = "s3://verticalbroker-prod-raw-trades/trades/2024/01/15/"
OUTPUT_PATH = "s3://verticalbroker-prod-processed/trades/"
AGG_OUTPUT_PATH = "s3://verticalbroker-prod-processed/aggregated/"


def process_trades():
    # ERROR 5 (P0): No schema definition — schema inference on JSON is unreliable
    # Inferred schema may change between runs (quantity as string vs int)
    df = spark.read.json(INPUT_PATH)

    # ERROR 6 (P0): Using float/double for financial calculations!
    # Spark infers price as DoubleType from JSON — loses precision
    print(f"Read {df.count()} records")  # ERROR 7 (P1): Unnecessary .count() triggers full scan

    # ERROR 8 (P1): No null checks or data validation
    # If symbol is null, this just propagates nulls silently
    df = df.withColumn("total_amount", F.col("quantity") * F.col("price"))

    # ERROR 9 (P0): No deduplication!
    # If same trade appears multiple times (SQS at-least-once), all duplicates are written
    # Customer shows up multiple times in reports

    # ERROR 10 (P1): collect() on potentially huge dataset
    # Pulls ALL data to driver memory — will OOM on production volumes
    all_symbols = df.select("symbol").distinct().collect()
    print(f"Processing symbols: {all_symbols}")

    # ERROR 11 (P2): No partitioning on write — creates huge monolithic files
    # Athena queries will scan the entire dataset for every query
    df.write.mode("append").parquet(OUTPUT_PATH)
    # ERROR 12 (P0): mode("append") is NOT idempotent!
    # If job fails halfway and reruns, you get DUPLICATE data

    # ERROR 13 (P1): repartition(1) — forces all data to single partition
    # Kills parallelism, creates one huge file, single executor does all work
    agg_df = (
        df.groupBy("symbol")
        .agg(
            F.count("*").alias("trade_count"),
            F.sum("total_amount").alias("total_value"),
            # ERROR 14 (P0): avg on DoubleType — floating-point precision loss
            F.avg("price").alias("avg_price"),
        )
    )

    agg_df.repartition(1).write.mode("overwrite").parquet(AGG_OUTPUT_PATH)
    # ERROR 15 (P2): No partitioning by date — can't query efficiently

    # ERROR 16 (P1): Printing PII/sensitive business data
    agg_df.show(100)

    print("ETL complete!")


# ERROR 17 (P2): No error handling at all — job crashes with cryptic Spark errors
# ERROR 18 (P1): No metrics, no monitoring, no quality gates
# ERROR 19 (P1): Default shuffle partitions (200) — likely too many for this data volume
# ERROR 20 (P0): No dead letter handling — malformed records silently dropped or crash the job

if __name__ == "__main__":
    process_trades()
    spark.stop()

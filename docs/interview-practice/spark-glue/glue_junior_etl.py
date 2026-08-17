"""
Vertical Broker — Trade ETL Pipeline (Junior Developer Submission)
===================================================================
AWS Glue PySpark Job — Supposed to do Bronze/Silver/Gold processing.
Contains multiple production-critical errors for peer review.
"""

import sys
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.sql import functions as F

# ERROR 1 (P2): All three layers in ONE job — no separation of concerns
# If Gold fails, Bronze and Silver must rerun too

args = getResolvedOptions(sys.argv, ["JOB_NAME"])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)


# ERROR 2 (P1): Hardcoded production paths — no parameterization
# ERROR 3 (P1): Hardcoded date — can't run for different dates or backfill
INPUT_PATH = "s3://verticalbroker-prod-raw/trades/2024/01/15/"
BRONZE_PATH = "s3://verticalbroker-prod-bronze/trades/"
SILVER_PATH = "s3://verticalbroker-prod-silver/trades/"
GOLD_PATH = "s3://verticalbroker-prod-gold/trades/"


def run_etl():
    """Process everything in one monolithic function."""

    # =========================================================================
    # "BRONZE" LAYER
    # =========================================================================

    # ERROR 4 (P0): No schema enforcement — infers schema from data
    # Schema could change between runs (quantity as string one day, int the next)
    # This SILENTLY produces wrong results
    df = spark.read.json(INPUT_PATH)

    # ERROR 5 (P1): .count() before any processing — triggers full expensive scan
    # just for a print statement
    print(f"Total records: {df.count()}")

    # ERROR 6 (P0): No validation AT ALL
    # Null request_id, negative quantities, garbage symbols all pass through
    # Corrupt data flows into Silver and Gold layers unchecked

    # ERROR 7 (P1): No dead letter handling
    # Malformed records either crash the job or silently disappear

    # ERROR 8 (P2): No metadata columns (no ingestion timestamp, no lineage)
    # Can't tell WHEN data was ingested or WHERE it came from

    # ERROR 9 (P0): mode("append") — NOT idempotent!
    # If job fails and reruns, Bronze gets DUPLICATE records
    # These duplicates propagate to Silver and Gold
    df.write.mode("append").parquet(BRONZE_PATH)

    # =========================================================================
    # "SILVER" LAYER
    # =========================================================================

    # ERROR 10 (P1): Re-reading what was just written — unnecessary I/O
    # Also reads ALL historical Bronze data, not just today's partition
    silver_df = spark.read.parquet(BRONZE_PATH)

    # ERROR 11 (P0): Float arithmetic for money!
    # price is inferred as DoubleType from JSON
    # quantity * price in floating point = precision loss
    silver_df = silver_df.withColumn(
        "total_amount", F.col("quantity") * F.col("price")
    )

    # ERROR 12 (P0): No deduplication across runs
    # Duplicate records from Bronze (ERROR 9) are never cleaned
    # Customer appears multiple times in reports

    # ERROR 13 (P1): No partitioning — writes one massive file
    # Every Athena query does full table scan ($$$)
    silver_df.write.mode("overwrite").parquet(SILVER_PATH)
    # ERROR 14 (P0): mode("overwrite") on ENTIRE table, not partition!
    # This DELETES all historical Silver data and replaces with just today!
    # All previous days' data is GONE

    # =========================================================================
    # "GOLD" LAYER
    # =========================================================================

    # ERROR 15 (P1): Reading from just-overwritten Silver (only has today's data
    # because of ERROR 14)
    gold_df = spark.read.parquet(SILVER_PATH)

    # ERROR 16 (P2): Only one aggregation — should have multiple Gold tables
    # (daily summary, customer activity, exchange volume, hourly patterns)
    agg_df = (
        gold_df
        .groupBy("symbol")
        .agg(
            F.count("*").alias("total_trades"),
            F.sum("total_amount").alias("total_value"),  # ERROR 11: float sum
            F.avg("price").alias("avg_price"),           # ERROR 11: float avg
        )
    )

    # ERROR 17 (P1): repartition(1) — forces ALL data through single executor
    # Kills parallelism, creates bottleneck, single point of failure
    # On large datasets, this causes OOM on one executor while others sit idle
    agg_df.repartition(1).write.mode("overwrite").parquet(GOLD_PATH)

    # ERROR 18 (P1): .show() in production — outputs data to driver stdout
    # Contains customer financial aggregations (business-sensitive)
    # .show() also triggers an extra action (computation)
    agg_df.show(1000)

    # ERROR 19 (P0): No quality gates — if 90% of data is garbage, we still write it
    # Downstream dashboards show wrong numbers, executives make bad decisions

    # ERROR 20 (P1): collect() on potentially millions of rows → driver OOM
    all_results = agg_df.collect()
    print(f"Results: {all_results}")

    # ERROR 21 (P2): No Glue Catalog integration — data not queryable via Athena
    # Users can't discover or query this data without knowing exact S3 paths

    # ERROR 22 (P1): No job.commit() — Glue bookmarks don't update
    # Next run will re-process the same files again (duplicates!)

    print("Done!")


# ERROR 23 (P2): No error handling — Glue job shows cryptic error in console
# No one knows what failed or why without reading Spark driver logs
# ERROR 24 (P1): No metrics emission — no CloudWatch custom metrics
# Can't set alarms on data quality or processing latency

if __name__ == "__main__":
    run_etl()
    spark.stop()  # ERROR 25 (P2): Glue manages SparkContext — don't stop it manually

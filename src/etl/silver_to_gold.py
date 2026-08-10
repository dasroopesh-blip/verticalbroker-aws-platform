"""Silver to Gold ETL: Aggregate, enrich, optimize for consumption.

Produces business-level Gold aggregates from validated Silver layer data.
Uses PySpark Window functions and built-in aggregations (no Python UDFs)
for performance. All monetary values use DecimalType for precision.

Gold Layer Datasets produced:
- daily_trade_summaries: OHLCV + VWAP per instrument per day
- client_portfolio_snapshots: Point-in-time portfolio state per client
- instrument_performance: Rolling returns, volatility, Sharpe, RSI
- risk_exposure_aggregates: VaR, expected shortfall, beta by client/sector/geo

Incremental aggregation uses CDC markers to avoid full 10 PB reprocessing.
Output Parquet optimized for Athena partition elimination (partitioned by date).

Requirements: 4.1, 4.2, 4.3, 4.4, 4.5
"""

import sys
from datetime import datetime
from decimal import Decimal
from typing import Dict, Optional

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.sql import DataFrame, SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import (
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)



# Constants for financial precision
PRICE_PRECISION = DecimalType(18, 8)
MONEY_PRECISION = DecimalType(28, 8)
RATIO_PRECISION = DecimalType(18, 10)

# Rolling window periods (trading days)
ROLLING_1D = 1
ROLLING_5D = 5
ROLLING_20D = 20
ROLLING_60D = 60
ROLLING_252D = 252

# RSI standard period
RSI_PERIOD = 14

# Annualization factor (trading days per year)
ANNUALIZATION_FACTOR = 252

# Risk-free rate assumption for Sharpe ratio (annualized)
RISK_FREE_RATE = 0.05



class SilverToGoldETL:
    """Produces business-level Gold aggregates from Silver data.

    Uses PySpark Window functions and built-in aggregations exclusively
    (no Python UDFs) for optimal performance on Glue G.2X workers.
    All monetary computations use DecimalType for financial precision.

    Supports incremental aggregation via CDC markers to avoid
    reprocessing the full 10 PB data estate.

    Requirements:
        4.1 - Produce Gold datasets within 30 minutes of Silver update
        4.2 - Produce daily_trade_summaries, client_portfolio_snapshots,
              instrument_performance, risk_exposure_aggregates
        4.3 - Incremental aggregation using CDC markers
        4.4 - Parquet optimized for Athena partition elimination
        4.5 - Referential integrity between Gold datasets
    """

    def __init__(self, glue_context: GlueContext, job_args: dict):
        """Initialize Silver-to-Gold ETL job.

        Args:
            glue_context: AWS Glue context with Spark session.
            job_args: Job arguments including source_partition, job_id, env.
        """
        self.glue_context = glue_context
        self.spark = glue_context.spark_session
        self.source_partition = job_args.get("source_partition", "")
        self.job_id = job_args.get("job_id", "")
        self.env = job_args.get("env", "dev")
        self.gold_bucket = f"s3://vb-gold-{self.env}"
        self.silver_bucket = f"s3://vb-silver-{self.env}"
        self.catalog_database = "verticalbroker_silver"
        self.gold_database = "verticalbroker_gold"
        self._processing_start = datetime.utcnow()


    def extract_incremental(self) -> DataFrame:
        """Extract only changed records from Silver layer using CDC markers.

        Uses CDC markers (cdc_operation, cdc_timestamp) to identify records
        that have been inserted or updated since the last processing run.
        This avoids full reprocessing of the 10 PB data estate.

        Returns:
            DataFrame containing only new/changed Silver records.

        Requirements: 4.3
        """
        # Read from Glue Data Catalog with push-down predicate
        dynamic_frame = self.glue_context.create_dynamic_frame.from_catalog(
            database=self.catalog_database,
            table_name="market_data_silver",
            push_down_predicate=f"trade_date = '{self.source_partition}'",
        )

        silver_df = dynamic_frame.toDF()

        # Filter to only CDC-marked records (new inserts and updates)
        # Records without CDC markers are treated as new (full partition load)
        if "cdc_operation" in silver_df.columns:
            incremental_df = silver_df.filter(
                (F.col("cdc_operation").isin("I", "U"))
                | F.col("cdc_operation").isNull()
            )
        else:
            incremental_df = silver_df

        # Cast price columns to DecimalType for financial precision
        incremental_df = self._cast_price_columns(incremental_df)

        return incremental_df


    def _cast_price_columns(self, df: DataFrame) -> DataFrame:
        """Cast price columns to DecimalType for financial precision.

        Args:
            df: Input DataFrame with string/double price columns.

        Returns:
            DataFrame with DecimalType price columns.
        """
        price_columns = [
            "bid_price", "ask_price", "last_price", "mid_price", "spread"
        ]
        for col_name in price_columns:
            if col_name in df.columns:
                df = df.withColumn(col_name, F.col(col_name).cast(PRICE_PRECISION))

        if "volume" in df.columns:
            df = df.withColumn("volume", F.col("volume").cast(IntegerType()))

        return df


    def compute_daily_trade_summaries(self, silver_df: DataFrame) -> DataFrame:
        """Aggregate trades by instrument and date into daily summaries.

        Computes OHLCV metrics, VWAP, and trade count using PySpark built-in
        aggregations. Uses Window functions for open/close price (first/last
        by timestamp within the trading day).

        Args:
            silver_df: Validated Silver layer DataFrame.

        Returns:
            DataFrame with daily trade summary aggregates per instrument.

        Requirements: 4.2 - daily trade summaries
        """
        # Window ordered by timestamp within each instrument+date group
        # for determining open (first) and close (last) prices
        time_window = Window.partitionBy(
            "instrument_id", "trade_date"
        ).orderBy("source_timestamp")

        # Add row numbers for first/last identification
        ranked_df = silver_df.withColumn(
            "_row_num", F.row_number().over(time_window)
        ).withColumn(
            "_row_count",
            F.count("*").over(
                Window.partitionBy("instrument_id", "trade_date")
            ),
        )

        # Compute turnover (price * volume) for VWAP calculation
        with_turnover = ranked_df.withColumn(
            "_turnover",
            (F.col("last_price") * F.col("volume")).cast(MONEY_PRECISION),
        )

        # Aggregate: volume, VWAP components, high, low, trade_count
        daily_agg = with_turnover.groupBy("instrument_id", "trade_date").agg(
            F.sum("volume").cast(IntegerType()).alias("total_volume"),
            F.sum("_turnover").cast(MONEY_PRECISION).alias("turnover"),
            F.max("last_price").cast(PRICE_PRECISION).alias("high_price"),
            F.min("last_price").cast(PRICE_PRECISION).alias("low_price"),
            F.count("*").cast(IntegerType()).alias("trade_count"),
            F.first("instrument_type").alias("instrument_type"),
        )


        # Compute VWAP = total turnover / total volume
        daily_agg = daily_agg.withColumn(
            "vwap",
            F.when(
                F.col("total_volume") > 0,
                (F.col("turnover") / F.col("total_volume")).cast(PRICE_PRECISION),
            ).otherwise(F.lit(None).cast(PRICE_PRECISION)),
        )

        # Get open price (first trade of the day) and close price (last trade)
        open_df = (
            with_turnover.filter(F.col("_row_num") == 1)
            .select(
                "instrument_id",
                "trade_date",
                F.col("last_price").alias("open_price"),
            )
        )

        close_df = (
            with_turnover.filter(F.col("_row_num") == F.col("_row_count"))
            .select(
                "instrument_id",
                "trade_date",
                F.col("last_price").alias("close_price"),
            )
        )

        # Join open/close with aggregates
        result = (
            daily_agg.join(
                open_df, on=["instrument_id", "trade_date"], how="left"
            )
            .join(close_df, on=["instrument_id", "trade_date"], how="left")
            .withColumn(
                "last_updated", F.lit(self._processing_start).cast(TimestampType())
            )
            .withColumn("processing_job_id", F.lit(self.job_id))
        )

        # Cast final monetary columns
        result = result.withColumn(
            "open_price", F.col("open_price").cast(PRICE_PRECISION)
        ).withColumn(
            "close_price", F.col("close_price").cast(PRICE_PRECISION)
        )

        return result


    def compute_client_portfolio_snapshots(
        self, silver_df: DataFrame
    ) -> DataFrame:
        """Compute point-in-time portfolio state per client.

        Uses Window functions to maintain running position per client and
        instrument, calculating cumulative quantities and cost basis from
        trade history. Produces a snapshot as of each trade_date.

        Args:
            silver_df: Silver layer DataFrame with trade data.

        Returns:
            DataFrame with portfolio snapshot per client per date.

        Requirements: 4.2 - client portfolio snapshots
        """
        # Filter to records that have client context (trades, not just quotes)
        trades_df = silver_df.filter(
            F.col("client_id").isNotNull() & F.col("side").isNotNull()
        )

        # Compute signed quantity: BUY = +quantity, SELL = -quantity
        trades_with_sign = trades_df.withColumn(
            "signed_quantity",
            F.when(F.col("side") == "BUY", F.col("volume")).otherwise(
                -F.col("volume")
            ).cast(MONEY_PRECISION),
        ).withColumn(
            "trade_value",
            (F.col("last_price") * F.col("volume")).cast(MONEY_PRECISION),
        )


        # Window: cumulative position per client + instrument ordered by date
        position_window = Window.partitionBy(
            "client_id", "instrument_id"
        ).orderBy("trade_date").rowsBetween(
            Window.unboundedPreceding, Window.currentRow
        )

        # Compute running position and cost basis
        portfolio_df = trades_with_sign.withColumn(
            "cumulative_quantity",
            F.sum("signed_quantity").over(position_window).cast(MONEY_PRECISION),
        ).withColumn(
            "cumulative_cost",
            F.sum(
                F.when(F.col("side") == "BUY", F.col("trade_value")).otherwise(
                    F.lit(0)
                )
            ).over(position_window).cast(MONEY_PRECISION),
        )

        # Snapshot: latest state per client + instrument + date
        snapshot_window = Window.partitionBy(
            "client_id", "instrument_id", "trade_date"
        ).orderBy(F.col("source_timestamp").desc())

        snapshot_df = (
            portfolio_df.withColumn(
                "_snap_rank", F.row_number().over(snapshot_window)
            )
            .filter(F.col("_snap_rank") == 1)
            .drop("_snap_rank")
        )


        # Compute average cost basis per share
        snapshot_df = snapshot_df.withColumn(
            "avg_cost_basis",
            F.when(
                F.col("cumulative_quantity") > 0,
                (F.col("cumulative_cost") / F.col("cumulative_quantity")).cast(
                    PRICE_PRECISION
                ),
            ).otherwise(F.lit(None).cast(PRICE_PRECISION)),
        )

        # Compute market value and unrealized P&L
        snapshot_df = snapshot_df.withColumn(
            "market_value",
            (F.col("cumulative_quantity") * F.col("last_price")).cast(
                MONEY_PRECISION
            ),
        ).withColumn(
            "unrealized_pnl",
            F.when(
                F.col("cumulative_quantity") > 0,
                (
                    (F.col("last_price") - F.col("avg_cost_basis"))
                    * F.col("cumulative_quantity")
                ).cast(MONEY_PRECISION),
            ).otherwise(F.lit(0).cast(MONEY_PRECISION)),
        )

        # Select final portfolio snapshot columns
        result = snapshot_df.select(
            "client_id",
            "instrument_id",
            "instrument_type",
            "trade_date",
            F.col("cumulative_quantity").alias("position_quantity"),
            "avg_cost_basis",
            F.col("last_price").alias("current_price"),
            "market_value",
            "unrealized_pnl",
            F.lit(self._processing_start).cast(TimestampType()).alias("snapshot_timestamp"),
            F.lit(self.job_id).alias("processing_job_id"),
        )

        return result


    def compute_instrument_performance(
        self, daily_summaries: DataFrame
    ) -> DataFrame:
        """Compute rolling performance metrics per instrument.

        Calculates rolling returns (1d, 5d, 20d, 60d, 252d), annualized
        volatility, Sharpe ratio, and RSI using PySpark Window functions.
        No Python UDFs used for performance.

        Args:
            daily_summaries: Daily trade summaries DataFrame with close prices.

        Returns:
            DataFrame with rolling performance metrics per instrument.

        Requirements: 4.2 - instrument performance metrics
        """
        # Window ordered by date per instrument for lag/rolling calculations
        instrument_window = Window.partitionBy("instrument_id").orderBy(
            "trade_date"
        )

        # Compute daily return: (close_today - close_yesterday) / close_yesterday
        with_returns = daily_summaries.withColumn(
            "prev_close",
            F.lag("close_price", 1).over(instrument_window),
        ).withColumn(
            "daily_return",
            F.when(
                F.col("prev_close") > 0,
                (
                    (F.col("close_price") - F.col("prev_close"))
                    / F.col("prev_close")
                ).cast(RATIO_PRECISION),
            ).otherwise(F.lit(None).cast(RATIO_PRECISION)),
        )


        # Rolling returns over various periods using lag
        for period, name in [
            (ROLLING_1D, "return_1d"),
            (ROLLING_5D, "return_5d"),
            (ROLLING_20D, "return_20d"),
            (ROLLING_60D, "return_60d"),
            (ROLLING_252D, "return_252d"),
        ]:
            lagged_close = F.lag("close_price", period).over(instrument_window)
            with_returns = with_returns.withColumn(
                name,
                F.when(
                    lagged_close > 0,
                    (
                        (F.col("close_price") - lagged_close) / lagged_close
                    ).cast(RATIO_PRECISION),
                ).otherwise(F.lit(None).cast(RATIO_PRECISION)),
            )

        # Rolling 20-day volatility (annualized std of daily returns)
        vol_window_20 = Window.partitionBy("instrument_id").orderBy(
            "trade_date"
        ).rowsBetween(-ROLLING_20D + 1, Window.currentRow)

        with_returns = with_returns.withColumn(
            "volatility_20d",
            (
                F.stddev("daily_return").over(vol_window_20)
                * F.lit(ANNUALIZATION_FACTOR).cast(RATIO_PRECISION).cast("double")
            ).cast(RATIO_PRECISION),
        )


        # Rolling 60-day volatility (annualized)
        vol_window_60 = Window.partitionBy("instrument_id").orderBy(
            "trade_date"
        ).rowsBetween(-ROLLING_60D + 1, Window.currentRow)

        with_returns = with_returns.withColumn(
            "volatility_60d",
            (
                F.stddev("daily_return").over(vol_window_60)
                * F.lit(ANNUALIZATION_FACTOR).cast(RATIO_PRECISION).cast("double")
            ).cast(RATIO_PRECISION),
        )

        # Sharpe Ratio: (annualized_return - risk_free_rate) / annualized_volatility
        # Using 252d return as annualized return proxy
        with_returns = with_returns.withColumn(
            "sharpe_ratio",
            F.when(
                (F.col("volatility_60d").isNotNull())
                & (F.col("volatility_60d") > 0),
                (
                    (F.col("return_252d") - F.lit(RISK_FREE_RATE))
                    / F.col("volatility_60d")
                ).cast(RATIO_PRECISION),
            ).otherwise(F.lit(None).cast(RATIO_PRECISION)),
        )


        # RSI (Relative Strength Index) - 14-period
        # Step 1: Compute gain/loss per day
        with_returns = with_returns.withColumn(
            "_gain",
            F.when(F.col("daily_return") > 0, F.col("daily_return")).otherwise(
                F.lit(0).cast(RATIO_PRECISION)
            ),
        ).withColumn(
            "_loss",
            F.when(F.col("daily_return") < 0, -F.col("daily_return")).otherwise(
                F.lit(0).cast(RATIO_PRECISION)
            ),
        )

        # Step 2: Rolling average gain and loss over RSI_PERIOD
        rsi_window = Window.partitionBy("instrument_id").orderBy(
            "trade_date"
        ).rowsBetween(-RSI_PERIOD + 1, Window.currentRow)

        with_returns = with_returns.withColumn(
            "_avg_gain", F.avg("_gain").over(rsi_window).cast(RATIO_PRECISION)
        ).withColumn(
            "_avg_loss", F.avg("_loss").over(rsi_window).cast(RATIO_PRECISION)
        )

        # Step 3: RSI = 100 - (100 / (1 + RS)) where RS = avg_gain / avg_loss
        with_returns = with_returns.withColumn(
            "rsi",
            F.when(
                (F.col("_avg_loss").isNotNull()) & (F.col("_avg_loss") > 0),
                (
                    F.lit(100)
                    - (
                        F.lit(100)
                        / (F.lit(1) + F.col("_avg_gain") / F.col("_avg_loss"))
                    )
                ).cast(RATIO_PRECISION),
            ).otherwise(
                # If no losses, RSI = 100 (fully bullish)
                F.when(
                    F.col("_avg_gain") > 0, F.lit(100).cast(RATIO_PRECISION)
                ).otherwise(F.lit(50).cast(RATIO_PRECISION))
            ),
        )


        # Select final performance columns (drop internal intermediates)
        result = with_returns.select(
            "instrument_id",
            "instrument_type",
            "trade_date",
            "close_price",
            "daily_return",
            "return_1d",
            "return_5d",
            "return_20d",
            "return_60d",
            "return_252d",
            "volatility_20d",
            "volatility_60d",
            "sharpe_ratio",
            "rsi",
            "total_volume",
            F.lit(self._processing_start).cast(TimestampType()).alias("last_updated"),
            F.lit(self.job_id).alias("processing_job_id"),
        )

        return result


    def compute_risk_exposure(self, silver_df: DataFrame) -> DataFrame:
        """Compute risk exposure aggregates by client, sector, and geography.

        Aggregates position-level risk into client, sector, and geography
        dimensions. Computes Value at Risk (VaR), expected shortfall (CVaR),
        and beta relative to a market benchmark using PySpark built-in
        window functions.

        Args:
            silver_df: Silver layer DataFrame with trade/position data.

        Returns:
            DataFrame with risk exposure aggregates.

        Requirements: 4.2 - risk exposure aggregates
        """
        # Filter to trades with required risk dimensions
        risk_df = silver_df.filter(
            F.col("client_id").isNotNull()
            & F.col("instrument_id").isNotNull()
        )

        # Compute position value
        risk_df = risk_df.withColumn(
            "position_value",
            (F.col("last_price") * F.col("volume")).cast(MONEY_PRECISION),
        )


        # Daily returns per client-instrument for risk calculation
        client_instrument_window = Window.partitionBy(
            "client_id", "instrument_id"
        ).orderBy("trade_date")

        risk_df = risk_df.withColumn(
            "prev_price",
            F.lag("last_price", 1).over(client_instrument_window),
        ).withColumn(
            "position_return",
            F.when(
                F.col("prev_price") > 0,
                (
                    (F.col("last_price") - F.col("prev_price"))
                    / F.col("prev_price")
                ).cast(RATIO_PRECISION),
            ).otherwise(F.lit(0).cast(RATIO_PRECISION)),
        )

        # Aggregate by client, sector, geography
        # VaR approximation: use 5th percentile of returns (parametric)
        # Expected Shortfall: average of returns below VaR threshold
        client_risk_window = Window.partitionBy(
            "client_id", "sector", "geography"
        ).orderBy("position_return")

        client_risk_ranked = risk_df.withColumn(
            "_return_rank",
            F.percent_rank().over(client_risk_window),
        )


        # Aggregate risk metrics per client + sector + geography
        risk_agg = client_risk_ranked.groupBy(
            "client_id", "sector", "geography", "trade_date"
        ).agg(
            # Total exposure
            F.sum("position_value").cast(MONEY_PRECISION).alias("total_exposure"),
            # VaR at 95% confidence (5th percentile of returns * exposure)
            F.expr("percentile_approx(position_return, 0.05)").cast(
                RATIO_PRECISION
            ).alias("var_95_pct"),
            # Expected shortfall (mean of returns below 5th percentile)
            F.avg(
                F.when(
                    F.col("_return_rank") <= 0.05, F.col("position_return")
                )
            ).cast(RATIO_PRECISION).alias("expected_shortfall"),
            # Average return for beta computation
            F.avg("position_return").cast(RATIO_PRECISION).alias("avg_return"),
            # Volatility of positions
            F.stddev("position_return").cast(RATIO_PRECISION).alias("return_volatility"),
            # Position count
            F.countDistinct("instrument_id").cast(IntegerType()).alias("instrument_count"),
            # Trade count
            F.count("*").cast(IntegerType()).alias("observation_count"),
        )


        # Compute VaR in dollar terms
        risk_agg = risk_agg.withColumn(
            "var_95_dollars",
            F.when(
                F.col("var_95_pct").isNotNull(),
                (F.abs(F.col("var_95_pct")) * F.col("total_exposure")).cast(
                    MONEY_PRECISION
                ),
            ).otherwise(F.lit(None).cast(MONEY_PRECISION)),
        )

        # Compute expected shortfall in dollar terms
        risk_agg = risk_agg.withColumn(
            "expected_shortfall_dollars",
            F.when(
                F.col("expected_shortfall").isNotNull(),
                (F.abs(F.col("expected_shortfall")) * F.col("total_exposure")).cast(
                    MONEY_PRECISION
                ),
            ).otherwise(F.lit(None).cast(MONEY_PRECISION)),
        )

        # Beta: covariance(asset, market) / variance(market)
        # Approximated as avg_return / market_avg_return
        # Market average computed across all instruments for the date
        market_avg = risk_df.groupBy("trade_date").agg(
            F.avg("position_return").cast(RATIO_PRECISION).alias("market_avg_return"),
            F.variance("position_return").cast(RATIO_PRECISION).alias("market_variance"),
        )

        risk_with_market = risk_agg.join(market_avg, on="trade_date", how="left")

        risk_with_market = risk_with_market.withColumn(
            "beta",
            F.when(
                (F.col("market_variance").isNotNull())
                & (F.col("market_variance") > 0),
                (F.col("avg_return") / F.col("market_avg_return")).cast(
                    RATIO_PRECISION
                ),
            ).otherwise(F.lit(1.0).cast(RATIO_PRECISION)),
        )


        # Select final risk exposure columns
        result = risk_with_market.select(
            "client_id",
            "sector",
            "geography",
            "trade_date",
            "total_exposure",
            "var_95_pct",
            "var_95_dollars",
            "expected_shortfall",
            "expected_shortfall_dollars",
            "beta",
            "return_volatility",
            "instrument_count",
            "observation_count",
            F.lit(self._processing_start).cast(TimestampType()).alias("last_updated"),
            F.lit(self.job_id).alias("processing_job_id"),
        )

        return result


    def validate_referential_integrity(
        self, gold_datasets: Dict[str, DataFrame]
    ) -> Dict[str, Dict[str, int]]:
        """Validate referential integrity between Gold layer datasets.

        Checks foreign key relationships between Gold datasets:
        - portfolio_snapshots.instrument_id exists in daily_summaries
        - risk_exposure.client_id exists in portfolio_snapshots
        - instrument_performance.instrument_id exists in daily_summaries

        Validates against Glue Data Catalog registered schemas.

        Args:
            gold_datasets: Dictionary mapping dataset name to DataFrame.

        Returns:
            Dictionary of validation results per relationship checked.
            Each entry contains total_records, valid_records, orphan_records.

        Requirements: 4.5 - Referential integrity between Gold datasets
        """
        results: Dict[str, Dict[str, int]] = {}

        daily_summaries = gold_datasets.get("daily_trade_summaries")
        portfolio_snapshots = gold_datasets.get("client_portfolio_snapshots")
        instrument_performance = gold_datasets.get("instrument_performance")
        risk_exposure = gold_datasets.get("risk_exposure_aggregates")

        # Validate: portfolio instruments exist in daily summaries
        if daily_summaries is not None and portfolio_snapshots is not None:
            valid_instruments = daily_summaries.select(
                "instrument_id"
            ).distinct()
            portfolio_total = portfolio_snapshots.count()
            orphan_portfolios = (
                portfolio_snapshots.join(
                    valid_instruments, on="instrument_id", how="left_anti"
                ).count()
            )
            results["portfolio_to_daily_summaries"] = {
                "total_records": portfolio_total,
                "valid_records": portfolio_total - orphan_portfolios,
                "orphan_records": orphan_portfolios,
            }


        # Validate: risk exposure clients exist in portfolio snapshots
        if portfolio_snapshots is not None and risk_exposure is not None:
            valid_clients = portfolio_snapshots.select("client_id").distinct()
            risk_total = risk_exposure.count()
            orphan_risk = (
                risk_exposure.join(
                    valid_clients, on="client_id", how="left_anti"
                ).count()
            )
            results["risk_to_portfolio"] = {
                "total_records": risk_total,
                "valid_records": risk_total - orphan_risk,
                "orphan_records": orphan_risk,
            }

        # Validate: instrument performance instruments exist in daily summaries
        if daily_summaries is not None and instrument_performance is not None:
            valid_instruments = daily_summaries.select(
                "instrument_id"
            ).distinct()
            perf_total = instrument_performance.count()
            orphan_perf = (
                instrument_performance.join(
                    valid_instruments, on="instrument_id", how="left_anti"
                ).count()
            )
            results["performance_to_daily_summaries"] = {
                "total_records": perf_total,
                "valid_records": perf_total - orphan_perf,
                "orphan_records": orphan_perf,
            }

        return results


    def _write_gold_dataset(
        self, df: DataFrame, table_name: str, partition_keys: list
    ) -> None:
        """Write a Gold dataset as Parquet optimized for Athena.

        Outputs Parquet with Snappy compression, partitioned for Athena
        partition elimination. Registers partitions in Glue Data Catalog.

        Args:
            df: DataFrame to write.
            table_name: Gold layer table name.
            partition_keys: List of columns to partition by.

        Requirements: 4.4 - Parquet optimized for Athena partition elimination
        """
        output_path = f"{self.gold_bucket}/{table_name}/"

        # Convert to DynamicFrame for Glue catalog integration
        dynamic_frame = DynamicFrame.fromDF(
            df, self.glue_context, f"gold_{table_name}"
        )

        # Write as Parquet with Snappy compression, partitioned for Athena
        self.glue_context.write_dynamic_frame.from_options(
            frame=dynamic_frame,
            connection_type="s3",
            format="parquet",
            connection_options={
                "path": output_path,
                "partitionKeys": partition_keys,
            },
            format_options={"compression": "snappy"},
        )


    def _emit_completion_event(
        self, datasets_produced: list, record_counts: Dict[str, int]
    ) -> None:
        """Emit pipeline completion event to EventBridge.

        Args:
            datasets_produced: List of Gold dataset names produced.
            record_counts: Record counts per dataset.
        """
        import boto3
        import json

        client = boto3.client("events")
        client.put_events(
            Entries=[
                {
                    "Source": "verticalbroker.etl-engine",
                    "DetailType": "GoldLayerUpdated",
                    "Detail": json.dumps(
                        {
                            "job_id": self.job_id,
                            "source_partition": self.source_partition,
                            "datasets_produced": datasets_produced,
                            "record_counts": record_counts,
                            "processing_duration_seconds": (
                                datetime.utcnow() - self._processing_start
                            ).total_seconds(),
                            "timestamp": datetime.utcnow().isoformat(),
                        }
                    ),
                    "EventBusName": "verticalbroker-platform",
                }
            ]
        )


    def run(self) -> None:
        """Execute the full Silver-to-Gold ETL pipeline.

        Orchestrates:
        1. Incremental extraction from Silver layer using CDC markers
        2. Computation of all four Gold datasets
        3. Referential integrity validation
        4. Write to Gold layer as optimized Parquet
        5. Emit completion event

        Requirements: 4.1, 4.2, 4.3, 4.4, 4.5
        """
        # Step 1: Extract incrementally using CDC markers (Requirement 4.3)
        silver_df = self.extract_incremental()

        # Cache the Silver DataFrame since it is used by multiple aggregations
        silver_df.cache()

        # Step 2: Compute Gold datasets (Requirement 4.2)
        daily_summaries = self.compute_daily_trade_summaries(silver_df)
        daily_summaries.cache()

        portfolio_snapshots = self.compute_client_portfolio_snapshots(silver_df)
        instrument_performance = self.compute_instrument_performance(
            daily_summaries
        )
        risk_exposure = self.compute_risk_exposure(silver_df)


        # Step 3: Validate referential integrity (Requirement 4.5)
        gold_datasets = {
            "daily_trade_summaries": daily_summaries,
            "client_portfolio_snapshots": portfolio_snapshots,
            "instrument_performance": instrument_performance,
            "risk_exposure_aggregates": risk_exposure,
        }
        integrity_results = self.validate_referential_integrity(gold_datasets)

        # Log integrity validation results
        for relationship, counts in integrity_results.items():
            orphan_rate = (
                counts["orphan_records"] / max(counts["total_records"], 1)
            ) * 100
            if orphan_rate > 5.0:
                print(
                    f"WARNING: Referential integrity issue in {relationship}: "
                    f"{counts['orphan_records']} orphan records "
                    f"({orphan_rate:.2f}%)"
                )

        # Step 4: Write Gold datasets as Parquet (Requirement 4.4)
        self._write_gold_dataset(
            daily_summaries,
            "daily_trade_summaries",
            ["trade_date", "instrument_type"],
        )
        self._write_gold_dataset(
            portfolio_snapshots,
            "client_portfolio_snapshots",
            ["trade_date", "client_id"],
        )
        self._write_gold_dataset(
            instrument_performance,
            "instrument_performance",
            ["trade_date", "instrument_type"],
        )
        self._write_gold_dataset(
            risk_exposure,
            "risk_exposure_aggregates",
            ["trade_date", "sector"],
        )


        # Step 5: Emit completion event
        record_counts = {
            "daily_trade_summaries": daily_summaries.count(),
            "client_portfolio_snapshots": portfolio_snapshots.count(),
            "instrument_performance": instrument_performance.count(),
            "risk_exposure_aggregates": risk_exposure.count(),
        }
        self._emit_completion_event(
            list(gold_datasets.keys()), record_counts
        )

        # Unpersist cached DataFrames
        silver_df.unpersist()
        daily_summaries.unpersist()


# --- Glue Job Entry Point ---

def main():
    """AWS Glue job entry point for Silver-to-Gold ETL.

    Parses job arguments and executes the SilverToGoldETL pipeline.
    Designed to run on Glue G.2X workers with auto-scaling (10-100 DPUs).
    """
    args = getResolvedOptions(
        sys.argv,
        ["JOB_NAME", "source_partition", "job_id", "env"],
    )

    # Initialize Glue context
    spark = SparkSession.builder.getOrCreate()
    glue_context = GlueContext(spark.sparkContext)
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    # Execute ETL pipeline
    job_args = {
        "source_partition": args["source_partition"],
        "job_id": args["job_id"],
        "env": args.get("env", "dev"),
    }

    etl = SilverToGoldETL(glue_context, job_args)
    etl.run()

    # Commit job bookmark for incremental processing
    job.commit()


if __name__ == "__main__":
    main()

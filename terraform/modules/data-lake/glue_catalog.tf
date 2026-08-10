# Glue Data Catalog - Databases, Tables, and Crawlers
# VerticalBroker AWS Data Engineering Platform
# Requirements: 2.4 (Register objects in Glue Data Catalog with partition metadata)
# Requirements: 3.2 (Validate against registered Glue Data Catalog schemas)
# Requirements: 4.4 (Parquet format optimized for Query Engine access)
# Requirements: 11.1 (Athena with Glue Data Catalog as metastore)

# ---------------------------------------------------------
# GLUE CATALOG DATABASES
# ---------------------------------------------------------

resource "aws_glue_catalog_database" "bronze" {
  name         = "verticalbroker_bronze"
  description  = "Raw data landing zone - unprocessed data from all sources in original format"
  catalog_id   = var.aws_account_id

  create_table_default_permission {
    permissions = ["ALL"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }

  tags = merge(var.tags, {
    DataClassification = "Confidential"
    Layer              = "Bronze"
  })
}

resource "aws_glue_catalog_database" "silver" {
  name         = "verticalbroker_silver"
  description  = "Cleansed, validated, and conformed data with schema enforcement"
  catalog_id   = var.aws_account_id

  create_table_default_permission {
    permissions = ["ALL"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }

  tags = merge(var.tags, {
    DataClassification = "Confidential"
    Layer              = "Silver"
  })
}


resource "aws_glue_catalog_database" "gold" {
  name         = "verticalbroker_gold"
  description  = "Business-level aggregates and curated datasets optimized for analytics"
  catalog_id   = var.aws_account_id

  create_table_default_permission {
    permissions = ["ALL"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }

  tags = merge(var.tags, {
    DataClassification = "Confidential"
    Layer              = "Gold"
  })
}

# ---------------------------------------------------------
# BRONZE TABLE: market_data_raw (JSON)
# Partitioned by: source, year, month, day, hour
# ---------------------------------------------------------

resource "aws_glue_catalog_table" "market_data_raw" {
  database_name = aws_glue_catalog_database.bronze.name
  name          = "market_data_raw"
  description   = "Raw market data from Bloomberg B-Pipe and Thomson Reuters feeds"
  catalog_id    = var.aws_account_id
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "json"
    "compressionType"       = "none"
    "typeOfData"            = "file"
    "EXTERNAL"              = "TRUE"
    "has_encrypted_data"    = "true"
  }


  storage_descriptor {
    location      = "s3://${aws_s3_bucket.bronze.bucket}/market_data/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "source_id"
      type = "string"
      comment = "Data source identifier (bloomberg_bpipe or thomson_reuters)"
    }
    columns {
      name = "instrument_id"
      type = "string"
      comment = "ISIN or CUSIP instrument identifier"
    }
    columns {
      name = "instrument_name"
      type = "string"
      comment = "Human-readable instrument name"
    }
    columns {
      name = "instrument_type"
      type = "string"
      comment = "EQUITY, BOND, OPTION, ETF, FUTURES"
    }
    columns {
      name = "exchange"
      type = "string"
      comment = "Exchange code (NYSE, NASDAQ, LSE, etc.)"
    }
    columns {
      name = "bid_price"
      type = "decimal(20,8)"
      comment = "Current bid price"
    }
    columns {
      name = "ask_price"
      type = "decimal(20,8)"
      comment = "Current ask price"
    }
    columns {
      name = "last_price"
      type = "decimal(20,8)"
      comment = "Last traded price"
    }
    columns {
      name = "volume"
      type = "bigint"
      comment = "Trading volume"
    }

    columns {
      name = "source_timestamp"
      type = "timestamp"
      comment = "When source generated the tick (UTC)"
    }
    columns {
      name = "ingestion_timestamp"
      type = "timestamp"
      comment = "When platform received the record"
    }
    columns {
      name = "schema_version"
      type = "string"
      comment = "Schema version (e.g., v2.3.1)"
    }
    columns {
      name = "partition_key"
      type = "string"
      comment = "Derived partition key: {source}/{instrument_type}/{date}"
    }
    columns {
      name = "sequence_number"
      type = "string"
      comment = "Kinesis sequence number for ordering"
    }
    columns {
      name = "shard_id"
      type = "string"
      comment = "Source Kinesis shard identifier"
    }
    columns {
      name = "is_delayed"
      type = "boolean"
      comment = "True if this is a delayed quote"
    }
    columns {
      name = "market_status"
      type = "string"
      comment = "PRE_MARKET, OPEN, CLOSED, AFTER_HOURS"
    }
  }

  partition_keys {
    name = "source"
    type = "string"
    comment = "Data source (bloomberg, thomson_reuters)"
  }
  partition_keys {
    name = "year"
    type = "string"
    comment = "Partition year (YYYY)"
  }
  partition_keys {
    name = "month"
    type = "string"
    comment = "Partition month (MM)"
  }
  partition_keys {
    name = "day"
    type = "string"
    comment = "Partition day (DD)"
  }
  partition_keys {
    name = "hour"
    type = "string"
    comment = "Partition hour (HH)"
  }
}


# ---------------------------------------------------------
# SILVER TABLE: market_data_silver (Parquet)
# Partitioned by: instrument_type, trade_date
# ---------------------------------------------------------

resource "aws_glue_catalog_table" "market_data_silver" {
  database_name = aws_glue_catalog_database.silver.name
  name          = "market_data_silver"
  description   = "Validated, deduplicated market data with schema enforcement"
  catalog_id    = var.aws_account_id
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "parquet"
    "compressionType"       = "snappy"
    "typeOfData"            = "file"
    "EXTERNAL"              = "TRUE"
    "has_encrypted_data"    = "true"
    "parquet.compression"   = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.silver.bucket}/market_data/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "instrument_id"
      type = "string"
      comment = "ISIN or CUSIP instrument identifier"
    }
    columns {
      name = "instrument_type"
      type = "string"
      comment = "EQUITY, BOND, OPTION, ETF, FUTURES"
    }
    columns {
      name = "trade_date"
      type = "string"
      comment = "Trade date (YYYY-MM-DD)"
    }

    columns {
      name = "bid_price"
      type = "decimal(20,8)"
      comment = "Validated bid price"
    }
    columns {
      name = "ask_price"
      type = "decimal(20,8)"
      comment = "Validated ask price"
    }
    columns {
      name = "last_price"
      type = "decimal(20,8)"
      comment = "Validated last traded price"
    }
    columns {
      name = "mid_price"
      type = "decimal(20,8)"
      comment = "Computed: (bid + ask) / 2"
    }
    columns {
      name = "spread"
      type = "decimal(20,8)"
      comment = "Computed: ask - bid"
    }
    columns {
      name = "volume"
      type = "bigint"
      comment = "Trading volume"
    }
    columns {
      name = "source_timestamp"
      type = "timestamp"
      comment = "Original source timestamp (UTC)"
    }
    columns {
      name = "processing_job_id"
      type = "string"
      comment = "Glue job ID that produced this record (lineage)"
    }
    columns {
      name = "quality_score"
      type = "double"
      comment = "Data quality score 0.0-1.0"
    }
    columns {
      name = "dedup_key"
      type = "string"
      comment = "Hash of instrument_id + timestamp + source for deduplication"
    }
  }

  partition_keys {
    name = "instrument_type"
    type = "string"
    comment = "Instrument type partition (EQUITY, BOND, etc.)"
  }
  partition_keys {
    name = "trade_date"
    type = "string"
    comment = "Trade date partition (YYYY-MM-DD)"
  }
}


# ---------------------------------------------------------
# GOLD TABLE: daily_trade_summaries (Parquet)
# Partitioned by: trade_date
# ---------------------------------------------------------

resource "aws_glue_catalog_table" "daily_trade_summaries" {
  database_name = aws_glue_catalog_database.gold.name
  name          = "daily_trade_summaries"
  description   = "Daily aggregated trade summary per instrument"
  catalog_id    = var.aws_account_id
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "parquet"
    "compressionType"       = "snappy"
    "typeOfData"            = "file"
    "EXTERNAL"              = "TRUE"
    "has_encrypted_data"    = "true"
    "parquet.compression"   = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.gold.bucket}/daily_trade_summaries/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "instrument_id"
      type = "string"
      comment = "ISIN or CUSIP instrument identifier"
    }
    columns {
      name = "instrument_name"
      type = "string"
      comment = "Human-readable instrument name"
    }
    columns {
      name = "trade_date"
      type = "string"
      comment = "Trade date (YYYY-MM-DD)"
    }

    columns {
      name = "open_price"
      type = "decimal(20,8)"
      comment = "Opening price for the day"
    }
    columns {
      name = "high_price"
      type = "decimal(20,8)"
      comment = "Highest price for the day"
    }
    columns {
      name = "low_price"
      type = "decimal(20,8)"
      comment = "Lowest price for the day"
    }
    columns {
      name = "close_price"
      type = "decimal(20,8)"
      comment = "Closing price for the day"
    }
    columns {
      name = "vwap"
      type = "decimal(20,8)"
      comment = "Volume-weighted average price"
    }
    columns {
      name = "total_volume"
      type = "bigint"
      comment = "Total trading volume for the day"
    }
    columns {
      name = "trade_count"
      type = "bigint"
      comment = "Number of trades executed"
    }
    columns {
      name = "turnover"
      type = "decimal(20,8)"
      comment = "Total turnover (price * quantity summed)"
    }
    columns {
      name = "daily_return_pct"
      type = "decimal(10,6)"
      comment = "Daily return percentage"
    }
    columns {
      name = "volatility_20d"
      type = "decimal(10,6)"
      comment = "20-day rolling volatility"
    }
    columns {
      name = "avg_spread"
      type = "decimal(20,8)"
      comment = "Average bid-ask spread for the day"
    }
    columns {
      name = "last_updated"
      type = "timestamp"
      comment = "Last computation timestamp"
    }
    columns {
      name = "source_record_count"
      type = "bigint"
      comment = "Number of source records aggregated"
    }
    columns {
      name = "quality_score"
      type = "double"
      comment = "Data quality score 0.0-1.0"
    }
  }

  partition_keys {
    name = "trade_date"
    type = "string"
    comment = "Trade date partition (YYYY-MM-DD)"
  }
}


# ---------------------------------------------------------
# GOLD TABLE: client_portfolio_snapshots (Parquet)
# Partitioned by: snapshot_date
# ---------------------------------------------------------

resource "aws_glue_catalog_table" "client_portfolio_snapshots" {
  database_name = aws_glue_catalog_database.gold.name
  name          = "client_portfolio_snapshots"
  description   = "Point-in-time portfolio state per client"
  catalog_id    = var.aws_account_id
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "parquet"
    "compressionType"       = "snappy"
    "typeOfData"            = "file"
    "EXTERNAL"              = "TRUE"
    "has_encrypted_data"    = "true"
    "parquet.compression"   = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.gold.bucket}/client_portfolio_snapshots/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "client_id"
      type = "string"
      comment = "Client identifier"
    }
    columns {
      name = "client_name"
      type = "string"
      comment = "Client full name (PII - restricted access)"
    }
    columns {
      name = "account_id"
      type = "string"
      comment = "Account identifier"
    }

    columns {
      name = "account_number"
      type = "string"
      comment = "Account number (PII - restricted access)"
    }
    columns {
      name = "ssn"
      type = "string"
      comment = "Social Security Number (PII - restricted access)"
    }
    columns {
      name = "service_tier"
      type = "string"
      comment = "FULL_SERVICE, SELF_SERVICE, AUTOMATED"
    }
    columns {
      name = "risk_profile"
      type = "string"
      comment = "CONSERVATIVE, MODERATE, AGGRESSIVE, VERY_AGGRESSIVE"
    }
    columns {
      name = "total_portfolio_value"
      type = "decimal(20,8)"
      comment = "Total portfolio value at snapshot time"
    }
    columns {
      name = "cash_balance"
      type = "decimal(20,8)"
      comment = "Cash balance at snapshot time"
    }
    columns {
      name = "total_positions"
      type = "int"
      comment = "Number of open positions"
    }
    columns {
      name = "unrealized_pnl"
      type = "decimal(20,8)"
      comment = "Total unrealized profit/loss"
    }
    columns {
      name = "realized_pnl_ytd"
      type = "decimal(20,8)"
      comment = "Year-to-date realized profit/loss"
    }
    columns {
      name = "margin_utilization_pct"
      type = "decimal(10,6)"
      comment = "Margin utilization percentage"
    }
    columns {
      name = "last_updated"
      type = "timestamp"
      comment = "Snapshot computation timestamp"
    }
    columns {
      name = "quality_score"
      type = "double"
      comment = "Data quality score 0.0-1.0"
    }
  }

  partition_keys {
    name = "snapshot_date"
    type = "string"
    comment = "Snapshot date partition (YYYY-MM-DD)"
  }
}


# ---------------------------------------------------------
# GOLD TABLE: instrument_performance (Parquet)
# Partitioned by: trade_date
# ---------------------------------------------------------

resource "aws_glue_catalog_table" "instrument_performance" {
  database_name = aws_glue_catalog_database.gold.name
  name          = "instrument_performance"
  description   = "Rolling performance metrics per instrument"
  catalog_id    = var.aws_account_id
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "parquet"
    "compressionType"       = "snappy"
    "typeOfData"            = "file"
    "EXTERNAL"              = "TRUE"
    "has_encrypted_data"    = "true"
    "parquet.compression"   = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.gold.bucket}/instrument_performance/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "instrument_id"
      type = "string"
      comment = "ISIN or CUSIP instrument identifier"
    }
    columns {
      name = "instrument_name"
      type = "string"
      comment = "Human-readable instrument name"
    }
    columns {
      name = "instrument_type"
      type = "string"
      comment = "EQUITY, BOND, OPTION, ETF, FUTURES"
    }
    columns {
      name = "exchange"
      type = "string"
      comment = "Exchange code"
    }
    columns {
      name = "sector"
      type = "string"
      comment = "Market sector"
    }

    columns {
      name = "return_1d"
      type = "decimal(10,6)"
      comment = "1-day return percentage"
    }
    columns {
      name = "return_5d"
      type = "decimal(10,6)"
      comment = "5-day return percentage"
    }
    columns {
      name = "return_20d"
      type = "decimal(10,6)"
      comment = "20-day return percentage"
    }
    columns {
      name = "return_60d"
      type = "decimal(10,6)"
      comment = "60-day return percentage"
    }
    columns {
      name = "return_252d"
      type = "decimal(10,6)"
      comment = "252-day (annual) return percentage"
    }
    columns {
      name = "volatility_20d"
      type = "decimal(10,6)"
      comment = "20-day rolling volatility"
    }
    columns {
      name = "volatility_60d"
      type = "decimal(10,6)"
      comment = "60-day rolling volatility"
    }
    columns {
      name = "sharpe_ratio"
      type = "decimal(10,6)"
      comment = "Sharpe ratio (20-day rolling)"
    }
    columns {
      name = "max_drawdown"
      type = "decimal(10,6)"
      comment = "Maximum drawdown percentage"
    }
    columns {
      name = "avg_daily_volume"
      type = "bigint"
      comment = "Average daily trading volume (20-day)"
    }
    columns {
      name = "relative_strength_index"
      type = "decimal(10,6)"
      comment = "RSI (14-day)"
    }
    columns {
      name = "last_updated"
      type = "timestamp"
      comment = "Last computation timestamp"
    }
    columns {
      name = "quality_score"
      type = "double"
      comment = "Data quality score 0.0-1.0"
    }
  }

  partition_keys {
    name = "trade_date"
    type = "string"
    comment = "Trade date partition (YYYY-MM-DD)"
  }
}


# ---------------------------------------------------------
# GOLD TABLE: risk_exposure_aggregates (Parquet)
# Partitioned by: report_date
# ---------------------------------------------------------

resource "aws_glue_catalog_table" "risk_exposure_aggregates" {
  database_name = aws_glue_catalog_database.gold.name
  name          = "risk_exposure_aggregates"
  description   = "Risk exposure aggregates by client, sector, geography"
  catalog_id    = var.aws_account_id
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"        = "parquet"
    "compressionType"       = "snappy"
    "typeOfData"            = "file"
    "EXTERNAL"              = "TRUE"
    "has_encrypted_data"    = "true"
    "parquet.compression"   = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.gold.bucket}/risk_exposure_aggregates/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "aggregation_level"
      type = "string"
      comment = "Level: CLIENT, SECTOR, GEOGRAPHY, FIRM"
    }
    columns {
      name = "aggregation_key"
      type = "string"
      comment = "Key for the aggregation level (client_id, sector name, region)"
    }
    columns {
      name = "client_id"
      type = "string"
      comment = "Client identifier (null for non-client aggregations)"
    }

    columns {
      name = "sector"
      type = "string"
      comment = "Market sector"
    }
    columns {
      name = "geography"
      type = "string"
      comment = "Geographic region"
    }
    columns {
      name = "total_exposure"
      type = "decimal(20,8)"
      comment = "Total exposure amount"
    }
    columns {
      name = "long_exposure"
      type = "decimal(20,8)"
      comment = "Long position exposure"
    }
    columns {
      name = "short_exposure"
      type = "decimal(20,8)"
      comment = "Short position exposure"
    }
    columns {
      name = "net_exposure"
      type = "decimal(20,8)"
      comment = "Net exposure (long - short)"
    }
    columns {
      name = "concentration_pct"
      type = "decimal(10,6)"
      comment = "Concentration percentage of total portfolio"
    }
    columns {
      name = "var_95"
      type = "decimal(20,8)"
      comment = "Value at Risk (95% confidence)"
    }
    columns {
      name = "var_99"
      type = "decimal(20,8)"
      comment = "Value at Risk (99% confidence)"
    }
    columns {
      name = "expected_shortfall"
      type = "decimal(20,8)"
      comment = "Expected shortfall (CVaR)"
    }
    columns {
      name = "beta"
      type = "decimal(10,6)"
      comment = "Portfolio beta relative to market"
    }
    columns {
      name = "last_updated"
      type = "timestamp"
      comment = "Last computation timestamp"
    }
    columns {
      name = "quality_score"
      type = "double"
      comment = "Data quality score 0.0-1.0"
    }
  }

  partition_keys {
    name = "report_date"
    type = "string"
    comment = "Report date partition (YYYY-MM-DD)"
  }
}


# ---------------------------------------------------------
# GLUE CRAWLERS - Automatic Partition Discovery
# ---------------------------------------------------------

resource "aws_glue_crawler" "bronze_market_data" {
  database_name = aws_glue_catalog_database.bronze.name
  name          = "${var.name_prefix}-bronze-market-data-crawler"
  role          = var.etl_glue_role_arn
  description   = "Discovers new partitions in Bronze market_data_raw table"

  s3_target {
    path       = "s3://${aws_s3_bucket.bronze.bucket}/market_data/"
    exclusions = ["_errors/**", "_tmp/**"]
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
    }
  })

  schedule = "cron(0/15 * * * ? *)"

  tags = merge(var.tags, {
    Layer = "Bronze"
  })
}

resource "aws_glue_crawler" "silver_market_data" {
  database_name = aws_glue_catalog_database.silver.name
  name          = "${var.name_prefix}-silver-market-data-crawler"
  role          = var.etl_glue_role_arn
  description   = "Discovers new partitions in Silver market_data_silver table"

  s3_target {
    path       = "s3://${aws_s3_bucket.silver.bucket}/market_data/"
    exclusions = ["_errors/**", "_tmp/**"]
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
    }
  })

  schedule = "cron(0/30 * * * ? *)"

  tags = merge(var.tags, {
    Layer = "Silver"
  })
}


resource "aws_glue_crawler" "gold_datasets" {
  database_name = aws_glue_catalog_database.gold.name
  name          = "${var.name_prefix}-gold-datasets-crawler"
  role          = var.etl_glue_role_arn
  description   = "Discovers new partitions in Gold layer datasets"

  s3_target {
    path       = "s3://${aws_s3_bucket.gold.bucket}/daily_trade_summaries/"
    exclusions = ["_tmp/**"]
  }

  s3_target {
    path       = "s3://${aws_s3_bucket.gold.bucket}/client_portfolio_snapshots/"
    exclusions = ["_tmp/**"]
  }

  s3_target {
    path       = "s3://${aws_s3_bucket.gold.bucket}/instrument_performance/"
    exclusions = ["_tmp/**"]
  }

  s3_target {
    path       = "s3://${aws_s3_bucket.gold.bucket}/risk_exposure_aggregates/"
    exclusions = ["_tmp/**"]
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
    }
  })

  schedule = "cron(0 * * * ? *)"

  tags = merge(var.tags, {
    Layer = "Gold"
  })
}

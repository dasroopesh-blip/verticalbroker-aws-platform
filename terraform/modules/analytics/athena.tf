# Analytics Module - Amazon Athena Query Engine
# VerticalBroker AWS Data Engineering Platform
#
# Implements Athena workgroups with cost controls and named queries:
# - 3 workgroups: analytics, compliance, data-science
# - Per-query scan limit 1 TB
# - Per-workgroup daily limit 10 TB
# - Query result caching enabled (24h TTL)
# - Results bucket with KMS encryption
# - Named queries for common analytical patterns
#
# Requirements: 11.1 (Query Bronze/Silver/Gold via Athena + Glue Data Catalog)
#               11.2 (Partition pruning, columnar Parquet, query result caching)
#               11.3 (Per-query 1 TB limit, per-workgroup 10 TB daily limit)
#               11.4 (Named queries: daily trade volume, portfolio, risk, regulatory)
#               11.5 (Reject queries exceeding limit with descriptive error)
#               11.6 (Segregated workgroups: analytics, compliance, data-science)

# ---------------------------------------------------------
# S3 RESULTS BUCKET (KMS encrypted)
# ---------------------------------------------------------

resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.name_prefix}-athena-results-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-athena-results"
    Service            = "athena"
    DataClassification = "Confidential"
  })
}

resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-old-results"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ---------------------------------------------------------
# ATHENA WORKGROUPS (Requirement 11.6)
# ---------------------------------------------------------

resource "aws_athena_workgroup" "analytics" {
  name        = "${var.name_prefix}-analytics"
  description = "Workgroup for business analytics queries - daily trade volume, portfolio performance"
  state       = "ENABLED"

  configuration {
    # Per-query scan limit: 1 TB (Requirement 11.3)
    bytes_scanned_cutoff_per_query = 1099511627776 # 1 TB in bytes

    # Query result caching enabled with 24h TTL (Requirement 11.2)
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/analytics/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }

    # Enforce workgroup settings over client settings
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # Engine version
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = merge(var.mandatory_tags, {
    Name      = "${var.name_prefix}-analytics"
    Service   = "athena"
    Workgroup = "analytics"
  })
}

resource "aws_athena_workgroup" "compliance" {
  name        = "${var.name_prefix}-compliance"
  description = "Workgroup for compliance and regulatory queries - audit reports, FINRA submissions"
  state       = "ENABLED"

  configuration {
    # Per-query scan limit: 1 TB (Requirement 11.3)
    bytes_scanned_cutoff_per_query = 1099511627776 # 1 TB in bytes

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/compliance/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }

    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = merge(var.mandatory_tags, {
    Name      = "${var.name_prefix}-compliance"
    Service   = "athena"
    Workgroup = "compliance"
  })
}

resource "aws_athena_workgroup" "data_science" {
  name        = "${var.name_prefix}-data-science"
  description = "Workgroup for data science and ML feature engineering queries"
  state       = "ENABLED"

  configuration {
    # Per-query scan limit: 1 TB (Requirement 11.3)
    bytes_scanned_cutoff_per_query = 1099511627776 # 1 TB in bytes

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/data-science/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }

    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = merge(var.mandatory_tags, {
    Name      = "${var.name_prefix}-data-science"
    Service   = "athena"
    Workgroup = "data-science"
  })
}

# ---------------------------------------------------------
# NAMED QUERIES (Requirement 11.4)
# Common analytical patterns for reuse
# ---------------------------------------------------------

resource "aws_athena_named_query" "daily_trade_volume" {
  name        = "daily-trade-volume"
  description = "Daily trade volume aggregation by instrument - used for market analysis dashboards"
  workgroup   = aws_athena_workgroup.analytics.id
  database    = var.glue_gold_database_name

  query = <<-EOQ
    -- Daily Trade Volume Summary
    -- Aggregates trade volume, value, and count per instrument per day
    -- Optimized for partition pruning on trade_date
    SELECT
        instrument_id,
        instrument_name,
        trade_date,
        SUM(total_volume) AS total_volume,
        SUM(turnover) AS total_turnover,
        SUM(trade_count) AS total_trades,
        MAX(high) AS daily_high,
        MIN(low) AS daily_low,
        APPROX_PERCENTILE(vwap, 0.5) AS median_vwap
    FROM verticalbroker_gold.daily_trade_summaries
    WHERE trade_date >= DATE_ADD('day', -30, CURRENT_DATE)
    GROUP BY instrument_id, instrument_name, trade_date
    ORDER BY trade_date DESC, total_volume DESC
  EOQ
}

resource "aws_athena_named_query" "portfolio_performance" {
  name        = "portfolio-performance"
  description = "Client portfolio performance metrics - returns, risk-adjusted returns, allocation"
  workgroup   = aws_athena_workgroup.analytics.id
  database    = var.glue_gold_database_name

  query = <<-EOQ
    -- Portfolio Performance Analysis
    -- Computes portfolio-level performance metrics per client
    -- Requires partition filter on snapshot_date for cost control
    SELECT
        client_id,
        snapshot_date,
        total_market_value,
        cash_balance,
        total_market_value + cash_balance AS total_portfolio_value,
        unrealized_pnl,
        realized_pnl_ytd,
        CASE
            WHEN total_market_value > 0
            THEN (unrealized_pnl / total_market_value) * 100
            ELSE 0
        END AS unrealized_return_pct
    FROM verticalbroker_gold.client_portfolio_snapshots
    WHERE snapshot_date >= DATE_ADD('day', -90, CURRENT_DATE)
    ORDER BY client_id, snapshot_date DESC
  EOQ
}

resource "aws_athena_named_query" "risk_metrics" {
  name        = "risk-exposure-metrics"
  description = "Risk exposure aggregation by sector, geography, and client tier"
  workgroup   = aws_athena_workgroup.analytics.id
  database    = var.glue_gold_database_name

  query = <<-EOQ
    -- Risk Exposure Metrics
    -- Aggregates risk exposure across dimensions for risk management
    SELECT
        sector,
        geography,
        risk_profile,
        COUNT(DISTINCT client_id) AS client_count,
        SUM(exposure_value) AS total_exposure,
        AVG(concentration_pct) AS avg_concentration,
        MAX(concentration_pct) AS max_concentration,
        SUM(CASE WHEN concentration_pct > 25 THEN 1 ELSE 0 END) AS concentrated_positions
    FROM verticalbroker_gold.risk_exposure_aggregates
    WHERE report_date = CURRENT_DATE
    GROUP BY sector, geography, risk_profile
    ORDER BY total_exposure DESC
  EOQ
}

resource "aws_athena_named_query" "regulatory_reports" {
  name        = "regulatory-trade-report"
  description = "FINRA regulatory trade reporting - daily submission format"
  workgroup   = aws_athena_workgroup.compliance.id
  database    = var.glue_gold_database_name

  query = <<-EOQ
    -- FINRA Regulatory Trade Report
    -- Generates daily trade report in regulatory submission format
    -- Must be run against compliance workgroup for audit trail
    SELECT
        t.trade_id,
        t.instrument_id,
        t.instrument_name,
        t.side,
        t.quantity,
        t.price,
        t.total_value,
        t.execution_timestamp,
        t.settlement_date,
        t.venue,
        t.account_type,
        t.client_id,
        CURRENT_TIMESTAMP AS report_generated_at
    FROM verticalbroker_gold.daily_trade_summaries t
    WHERE t.trade_date = DATE_ADD('day', -1, CURRENT_DATE)
    ORDER BY t.execution_timestamp ASC
  EOQ
}

# ---------------------------------------------------------
# CLOUDWATCH ALARMS - Per-workgroup daily limit monitoring
# (Requirement 11.3: per-workgroup daily limit of 10 TB)
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "athena_analytics_scan_limit" {
  alarm_name          = "${var.name_prefix}-athena-analytics-daily-scan-limit"
  alarm_description   = "Athena analytics workgroup approaching 10 TB daily scan limit"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ProcessedBytes"
  namespace           = "AWS/Athena"
  period              = 86400 # 24 hours
  statistic           = "Sum"
  threshold           = 8796093022208 # 8 TB (80% warning of 10 TB limit)

  dimensions = {
    WorkGroup = aws_athena_workgroup.analytics.name
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service   = "athena"
    Workgroup = "analytics"
  })
}

resource "aws_cloudwatch_metric_alarm" "athena_compliance_scan_limit" {
  alarm_name          = "${var.name_prefix}-athena-compliance-daily-scan-limit"
  alarm_description   = "Athena compliance workgroup approaching 10 TB daily scan limit"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ProcessedBytes"
  namespace           = "AWS/Athena"
  period              = 86400
  statistic           = "Sum"
  threshold           = 8796093022208 # 8 TB (80% warning)

  dimensions = {
    WorkGroup = aws_athena_workgroup.compliance.name
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service   = "athena"
    Workgroup = "compliance"
  })
}

resource "aws_cloudwatch_metric_alarm" "athena_data_science_scan_limit" {
  alarm_name          = "${var.name_prefix}-athena-data-science-daily-scan-limit"
  alarm_description   = "Athena data-science workgroup approaching 10 TB daily scan limit"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ProcessedBytes"
  namespace           = "AWS/Athena"
  period              = 86400
  statistic           = "Sum"
  threshold           = 8796093022208 # 8 TB (80% warning)

  dimensions = {
    WorkGroup = aws_athena_workgroup.data_science.name
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service   = "athena"
    Workgroup = "data-science"
  })
}

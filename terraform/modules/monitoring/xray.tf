# X-Ray Distributed Tracing Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Implements distributed tracing with:
# - Sampling rules: 5% normal traffic, 100% error paths
# - X-Ray groups for each service for focused trace analysis
# - Integration across Lambda, API Gateway, and Step Functions
#
# Requirements: 15.5

# ---------------------------------------------------------
# X-RAY SAMPLING RULES
# ---------------------------------------------------------

# Default sampling rule: 5% of normal traffic
resource "aws_xray_sampling_rule" "normal_traffic" {
  rule_name      = "${var.name_prefix}-normal-traffic"
  priority       = 1000
  reservoir_size = 5
  fixed_rate     = var.xray_normal_sampling_rate
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
  version        = 1

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-xray-normal-traffic"
  })
}

# Error path sampling rule: 100% of error responses
resource "aws_xray_sampling_rule" "error_paths" {
  rule_name      = "${var.name_prefix}-error-paths"
  priority       = 100
  reservoir_size = 50
  fixed_rate     = var.xray_error_sampling_rate
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
  version        = 1

  attributes = {
    "http.status_code" = "5*"
  }

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-xray-error-paths"
  })
}


# High-priority sampling for trade-critical paths (10% sampling)
resource "aws_xray_sampling_rule" "trade_paths" {
  rule_name      = "${var.name_prefix}-trade-paths"
  priority       = 500
  reservoir_size = 10
  fixed_rate     = 0.10
  url_path       = "/v1/orders*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "${var.name_prefix}-order-manager"
  resource_arn   = "*"
  version        = 1

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-xray-trade-paths"
  })
}

# ---------------------------------------------------------
# X-RAY GROUPS
# Groups provide filtered views of traces by service for
# focused analysis and alerting on service-specific issues.
# ---------------------------------------------------------

resource "aws_xray_group" "market_data_ingestion" {
  group_name        = "${var.name_prefix}-market-data-ingestion"
  filter_expression = "service(\"${var.name_prefix}-market-data-ingestion\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = merge(var.mandatory_tags, {
    Service = "market-data-ingestion"
    Name    = "${var.name_prefix}-xray-group-market-data-ingestion"
  })
}

resource "aws_xray_group" "order_manager" {
  group_name        = "${var.name_prefix}-order-manager"
  filter_expression = "service(\"${var.name_prefix}-order-manager\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = merge(var.mandatory_tags, {
    Service = "order-manager"
    Name    = "${var.name_prefix}-xray-group-order-manager"
  })
}


resource "aws_xray_group" "wallet_service" {
  group_name        = "${var.name_prefix}-wallet-service"
  filter_expression = "service(\"${var.name_prefix}-wallet-service\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = merge(var.mandatory_tags, {
    Service = "wallet-service"
    Name    = "${var.name_prefix}-xray-group-wallet-service"
  })
}

resource "aws_xray_group" "advisory_agent" {
  group_name        = "${var.name_prefix}-advisory-agent"
  filter_expression = "service(\"${var.name_prefix}-advisory-agent\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = merge(var.mandatory_tags, {
    Service = "advisory-agent"
    Name    = "${var.name_prefix}-xray-group-advisory-agent"
  })
}

resource "aws_xray_group" "etl_pipeline" {
  group_name        = "${var.name_prefix}-etl-pipeline"
  filter_expression = "service(\"${var.name_prefix}-etl-pipeline\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = merge(var.mandatory_tags, {
    Service = "etl-pipeline"
    Name    = "${var.name_prefix}-xray-group-etl-pipeline"
  })
}

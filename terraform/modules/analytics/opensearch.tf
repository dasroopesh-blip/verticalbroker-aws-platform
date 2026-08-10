# Analytics Module - OpenSearch Service
# VerticalBroker AWS Data Engineering Platform
#
# Implements multi-AZ OpenSearch domain with:
# - 3 dedicated master nodes (r6g.large.search)
# - 6 data nodes (r6g.2xlarge.search)
# - UltraWarm enabled for cost-effective warm tier
# - Index State Management: hot (0-30d), warm (30-90d), cold (90d-7yr), delete (>7yr)
# - Fine-grained access control mapped to IAM roles for PII field protection
# - VPC deployment in data subnets with security group
# - KMS encryption at rest, node-to-node encryption, HTTPS enforced
#
# Requirements: 9.1 (Indexing lag <10 min)
#               9.2 (Full-text search, sub-second queries)
#               9.3 (Multi-AZ cluster: 3 master, 6 data, UltraWarm)
#               9.4 (Fine-grained access control for PII)
#               9.5 (Indexing pipeline triggered by Gold Layer)
#               9.6 (ISM: hot 30d, warm 90d, cold 7yr, delete >7yr per FINRA)

# ---------------------------------------------------------
# DATA SOURCES
# ---------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "opensearch_access" {
  statement {
    sid    = "AllowIAMRoleAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.opensearch_access_role_arns
    }

    actions = [
      "es:ESHttpGet",
      "es:ESHttpPut",
      "es:ESHttpPost",
      "es:ESHttpDelete",
      "es:ESHttpHead",
    ]

    resources = [
      "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch_domain_name}/*"
    ]
  }
}

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  opensearch_domain_name = "${var.name_prefix}-search"

  # Index State Management policy (Requirement 9.6)
  ism_policy = jsonencode({
    policy = {
      policy_id   = "verticalbroker-lifecycle"
      description = "VerticalBroker index lifecycle: hot→warm→cold→delete per FINRA 4511"
      default_state = "hot"
      states = [
        {
          name = "hot"
          actions = [
            {
              rollover = {
                min_index_age = "30d"
                min_size       = "50gb"
              }
            }
          ]
          transitions = [
            {
              state_name = "warm"
              conditions = {
                min_index_age = "30d"
              }
            }
          ]
        },
        {
          name = "warm"
          actions = [
            {
              warm_migration = {}
            },
            {
              replica_count = {
                number_of_replicas = 1
              }
            }
          ]
          transitions = [
            {
              state_name = "cold"
              conditions = {
                min_index_age = "90d"
              }
            }
          ]
        },
        {
          name = "cold"
          actions = [
            {
              cold_migration = {}
            }
          ]
          transitions = [
            {
              state_name = "delete"
              conditions = {
                min_index_age = "2555d" # 7 years per FINRA 4511
              }
            }
          ]
        },
        {
          name = "delete"
          actions = [
            {
              delete = {}
            }
          ]
          transitions = []
        }
      ]
      ism_template = [
        {
          index_patterns = ["trade_records-*", "client_profiles-*"]
          priority       = 100
        }
      ]
    }
  })

  # Index mappings (Requirement 9.2)
  trade_records_index_template = jsonencode({
    index_patterns = ["trade_records-*"]
    template = {
      settings = {
        number_of_shards   = 12
        number_of_replicas = 2
        codec              = "best_compression"
        "index.refresh_interval" = "30s"
      }
      mappings = {
        properties = {
          trade_id             = { type = "keyword" }
          client_id            = { type = "keyword" }
          instrument_id        = { type = "keyword" }
          instrument_name      = { type = "text", analyzer = "standard" }
          side                 = { type = "keyword" }
          quantity             = { type = "double" }
          price                = { type = "double" }
          total_value          = { type = "double" }
          execution_timestamp  = { type = "date", format = "strict_date_optional_time" }
          settlement_date      = { type = "date" }
          venue                = { type = "keyword" }
          account_type         = { type = "keyword" }
          "@timestamp"         = { type = "date" }
        }
      }
    }
  })

  client_profiles_index_template = jsonencode({
    index_patterns = ["client_profiles-*"]
    template = {
      settings = {
        number_of_shards   = 6
        number_of_replicas = 2
      }
      mappings = {
        properties = {
          client_id      = { type = "keyword" }
          name           = { type = "text", fields = { keyword = { type = "keyword" } } }
          account_ids    = { type = "keyword" }
          risk_profile   = { type = "keyword" }
          advisor_id     = { type = "keyword" }
          account_type   = { type = "keyword" }
          kyc_status     = { type = "keyword" }
          created_date   = { type = "date" }
          last_activity  = { type = "date" }
        }
      }
    }
  })
}

# ---------------------------------------------------------
# OPENSEARCH DOMAIN (Requirement 9.3)
# ---------------------------------------------------------

resource "aws_opensearch_domain" "main" {
  domain_name    = local.opensearch_domain_name
  engine_version = var.opensearch_engine_version

  # Cluster configuration: 3 dedicated masters + 6 data nodes (Requirement 9.3)
  cluster_config {
    instance_type            = "r6g.2xlarge.search"
    instance_count           = 6
    dedicated_master_enabled = true
    dedicated_master_type    = "r6g.large.search"
    dedicated_master_count   = 3
    zone_awareness_enabled   = true

    zone_awareness_config {
      availability_zone_count = 3
    }

    # UltraWarm for cost-effective warm tier (Requirement 9.6)
    warm_enabled = true
    warm_type    = "ultrawarm1.medium.search"
    warm_count   = 3

    # Cold storage for FINRA 7-year retention
    cold_storage_options {
      enabled = true
    }
  }

  # VPC deployment in data subnets (Requirement 20.3)
  vpc_options {
    subnet_ids         = var.data_subnet_ids
    security_group_ids = [aws_security_group.opensearch.id]
  }

  # KMS encryption at rest (Requirement 14.1)
  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  # Node-to-node encryption (Requirement 14.2)
  node_to_node_encryption {
    enabled = true
  }

  # HTTPS enforcement (Requirement 14.2)
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-PFS-2023-10"
  }

  # Fine-grained access control (Requirement 9.4)
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false

    master_user_options {
      master_user_arn = var.opensearch_master_role_arn
    }
  }

  # EBS storage for data nodes
  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_ebs_volume_size
    iops        = var.opensearch_ebs_iops
    throughput  = var.opensearch_ebs_throughput
  }

  # Auto-tune for performance optimization
  auto_tune_options {
    desired_state       = "ENABLED"
    rollback_on_disable = "NO_ROLLBACK"

    maintenance_schedule {
      start_at = var.opensearch_maintenance_start
      duration {
        value = 2
        unit  = "HOURS"
      }
      cron_expression_for_recurrence = "cron(0 2 ? * SUN *)"
    }
  }

  # Access policies
  access_policies = data.aws_iam_policy_document.opensearch_access.json

  # Logging
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_index_slow.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_search_slow.arn
    log_type                 = "SEARCH_SLOW_LOGS"
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_error.arn
    log_type                 = "ES_APPLICATION_LOGS"
  }

  tags = merge(var.mandatory_tags, {
    Name               = local.opensearch_domain_name
    Service            = "opensearch"
    DataClassification = "Confidential"
  })
}

# ---------------------------------------------------------
# SECURITY GROUP (Requirement 20.6)
# ---------------------------------------------------------

resource "aws_security_group" "opensearch" {
  name_prefix = "${var.name_prefix}-opensearch-"
  description = "Security group for OpenSearch domain - allows HTTPS from compute subnets"
  vpc_id      = var.vpc_id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-opensearch-sg"
    Service = "opensearch"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "opensearch_ingress_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.compute_subnet_cidrs
  security_group_id = aws_security_group.opensearch.id
  description       = "Allow HTTPS from compute subnets"
}

resource "aws_security_group_rule" "opensearch_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.opensearch.id
  description       = "Allow all outbound traffic"
}

# ---------------------------------------------------------
# CLOUDWATCH LOG GROUPS
# ---------------------------------------------------------

resource "aws_cloudwatch_log_group" "opensearch_index_slow" {
  name              = "/aws/opensearch/${local.opensearch_domain_name}/index-slow-logs"
  retention_in_days = 90

  tags = merge(var.mandatory_tags, {
    Service = "opensearch"
  })
}

resource "aws_cloudwatch_log_group" "opensearch_search_slow" {
  name              = "/aws/opensearch/${local.opensearch_domain_name}/search-slow-logs"
  retention_in_days = 90

  tags = merge(var.mandatory_tags, {
    Service = "opensearch"
  })
}

resource "aws_cloudwatch_log_group" "opensearch_error" {
  name              = "/aws/opensearch/${local.opensearch_domain_name}/error-logs"
  retention_in_days = 90

  tags = merge(var.mandatory_tags, {
    Service = "opensearch"
  })
}

resource "aws_cloudwatch_log_resource_policy" "opensearch_logs" {
  policy_name = "${var.name_prefix}-opensearch-log-policy"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOpenSearchLogs"
        Effect    = "Allow"
        Principal = { Service = "es.amazonaws.com" }
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogStream",
        ]
        Resource = [
          "${aws_cloudwatch_log_group.opensearch_index_slow.arn}:*",
          "${aws_cloudwatch_log_group.opensearch_search_slow.arn}:*",
          "${aws_cloudwatch_log_group.opensearch_error.arn}:*",
        ]
      }
    ]
  })
}

# ---------------------------------------------------------
# CLOUDWATCH ALARMS (Requirement 15.2)
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "opensearch_cluster_status_red" {
  alarm_name          = "${var.name_prefix}-opensearch-cluster-red"
  alarm_description   = "OpenSearch cluster status is RED - data nodes unavailable"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ClusterStatus.red"
  namespace           = "AWS/ES"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1

  dimensions = {
    DomainName = aws_opensearch_domain.main.domain_name
    ClientId   = data.aws_caller_identity.current.account_id
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service = "opensearch"
  })
}

resource "aws_cloudwatch_metric_alarm" "opensearch_free_storage_low" {
  alarm_name          = "${var.name_prefix}-opensearch-storage-low"
  alarm_description   = "OpenSearch cluster free storage space below threshold"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/ES"
  period              = 300
  statistic           = "Minimum"
  threshold           = var.opensearch_free_storage_threshold_mb

  dimensions = {
    DomainName = aws_opensearch_domain.main.domain_name
    ClientId   = data.aws_caller_identity.current.account_id
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service = "opensearch"
  })
}

resource "aws_cloudwatch_metric_alarm" "opensearch_cpu_high" {
  alarm_name          = "${var.name_prefix}-opensearch-cpu-high"
  alarm_description   = "OpenSearch data node CPU utilization above 80%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ES"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DomainName = aws_opensearch_domain.main.domain_name
    ClientId   = data.aws_caller_identity.current.account_id
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service = "opensearch"
  })
}

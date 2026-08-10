# Analytics Module - Amazon Neptune Graph Database
# VerticalBroker AWS Data Engineering Platform
#
# Implements Neptune graph database cluster for relationship-based analytics:
# - Cluster: db.r6g.2xlarge (1 writer, 2 readers)
# - Auto-scaling at 70% CPU utilization
# - Subnet group in data subnets
# - Security group allowing port 8182 (Gremlin) from compute subnets only
# - IAM authentication enabled, KMS encryption
# - Backup retention 7 days, maintenance window configured
#
# Requirements: 10.1 (Graph model: clients, accounts, instruments, transactions)
#               10.2 (Incremental updates every 15 minutes from Gold Layer)
#               10.3 (Traversal results within 5 seconds for 4-hop queries)
#               10.4 (db.r6g.2xlarge, 1 writer, 2 readers, auto-scale at 70% CPU)
#               10.5 (Fraud detection: circular transactions, rapid transfers, velocity)
#               10.6 (API Gateway integration with parameterized query templates)

# ---------------------------------------------------------
# NEPTUNE CLUSTER (Requirement 10.4)
# ---------------------------------------------------------

resource "aws_neptune_cluster" "main" {
  cluster_identifier = "${var.name_prefix}-graph"

  engine         = "neptune"
  engine_version = var.neptune_engine_version

  # IAM authentication (Requirement 14.3)
  iam_database_authentication_enabled = true

  # KMS encryption at rest (Requirement 14.1)
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  # Backup (7-day retention)
  backup_retention_period   = 7
  preferred_backup_window   = var.neptune_backup_window
  preferred_maintenance_window = var.neptune_maintenance_window

  # Networking
  neptune_subnet_group_name = aws_neptune_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.neptune.id]

  # Parameter group
  neptune_cluster_parameter_group_name = aws_neptune_cluster_parameter_group.main.name

  # Deletion protection (production safety)
  deletion_protection = var.environment == "production" ? true : false

  # Skip final snapshot in non-prod
  skip_final_snapshot       = var.environment != "production"
  final_snapshot_identifier = var.environment == "production" ? "${var.name_prefix}-graph-final" : null

  # CloudWatch log exports
  enable_cloudwatch_logs_exports = ["audit"]

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-graph"
    Service            = "neptune"
    DataClassification = "Confidential"
  })
}

# ---------------------------------------------------------
# NEPTUNE INSTANCES (Requirement 10.4: 1 writer + 2 readers)
# ---------------------------------------------------------

resource "aws_neptune_cluster_instance" "writer" {
  identifier         = "${var.name_prefix}-graph-writer"
  cluster_identifier = aws_neptune_cluster.main.id
  instance_class     = var.neptune_instance_class
  engine             = "neptune"

  neptune_parameter_group_name = aws_neptune_parameter_group.main.name

  # Writer instance promotion priority
  promotion_tier = 0

  # Auto minor version upgrade
  auto_minor_version_upgrade = true

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-graph-writer"
    Service = "neptune"
    Role    = "writer"
  })
}

resource "aws_neptune_cluster_instance" "readers" {
  count = var.neptune_reader_count

  identifier         = "${var.name_prefix}-graph-reader-${count.index + 1}"
  cluster_identifier = aws_neptune_cluster.main.id
  instance_class     = var.neptune_instance_class
  engine             = "neptune"

  neptune_parameter_group_name = aws_neptune_parameter_group.main.name

  # Reader promotion priority (lower = higher priority for failover)
  promotion_tier = count.index + 1

  auto_minor_version_upgrade = true

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-graph-reader-${count.index + 1}"
    Service = "neptune"
    Role    = "reader"
  })
}

# ---------------------------------------------------------
# NEPTUNE AUTO-SCALING (Requirement 10.4: auto-scale at 70% CPU)
# ---------------------------------------------------------

resource "aws_appautoscaling_target" "neptune_readers" {
  service_namespace  = "neptune"
  scalable_dimension = "neptune:cluster:ReadReplicaCount"
  resource_id        = "cluster:${aws_neptune_cluster.main.cluster_identifier}"
  min_capacity       = var.neptune_reader_count
  max_capacity       = var.neptune_max_reader_count
}

resource "aws_appautoscaling_policy" "neptune_cpu_scaling" {
  name               = "${var.name_prefix}-neptune-cpu-scaling"
  service_namespace  = aws_appautoscaling_target.neptune_readers.service_namespace
  scalable_dimension = aws_appautoscaling_target.neptune_readers.scalable_dimension
  resource_id        = aws_appautoscaling_target.neptune_readers.resource_id
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "NeptuneReaderAverageCPUUtilization"
    }

    target_value       = 70.0 # Scale at 70% CPU (Requirement 10.4)
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

# ---------------------------------------------------------
# NEPTUNE SUBNET GROUP
# ---------------------------------------------------------

resource "aws_neptune_subnet_group" "main" {
  name        = "${var.name_prefix}-graph-subnets"
  description = "Neptune subnet group for VerticalBroker graph database - data subnets only"
  subnet_ids  = var.data_subnet_ids

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-graph-subnets"
    Service = "neptune"
  })
}

# ---------------------------------------------------------
# NEPTUNE PARAMETER GROUPS
# ---------------------------------------------------------

resource "aws_neptune_cluster_parameter_group" "main" {
  family      = var.neptune_parameter_group_family
  name        = "${var.name_prefix}-graph-cluster-params"
  description = "Cluster parameter group for VerticalBroker Neptune"

  parameter {
    name  = "neptune_enable_audit_log"
    value = "1"
  }

  parameter {
    name  = "neptune_query_timeout"
    value = "120000" # 120 seconds max query timeout
  }

  tags = merge(var.mandatory_tags, {
    Service = "neptune"
  })
}

resource "aws_neptune_parameter_group" "main" {
  family      = var.neptune_parameter_group_family
  name        = "${var.name_prefix}-graph-instance-params"
  description = "Instance parameter group for VerticalBroker Neptune"

  parameter {
    name  = "neptune_query_timeout"
    value = "120000"
  }

  tags = merge(var.mandatory_tags, {
    Service = "neptune"
  })
}

# ---------------------------------------------------------
# SECURITY GROUP (Requirement 10.6, 20.6)
# Allows Gremlin (port 8182) from compute subnets only
# ---------------------------------------------------------

resource "aws_security_group" "neptune" {
  name_prefix = "${var.name_prefix}-neptune-"
  description = "Security group for Neptune - allows Gremlin (8182) from compute subnets only"
  vpc_id      = var.vpc_id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-neptune-sg"
    Service = "neptune"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "neptune_ingress_gremlin" {
  type              = "ingress"
  from_port         = 8182
  to_port           = 8182
  protocol          = "tcp"
  cidr_blocks       = var.compute_subnet_cidrs
  security_group_id = aws_security_group.neptune.id
  description       = "Allow Gremlin access from compute subnets"
}

resource "aws_security_group_rule" "neptune_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.neptune.id
  description       = "Allow all outbound traffic"
}

# ---------------------------------------------------------
# CLOUDWATCH ALARMS (Requirement 15.2)
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "neptune_cpu_high" {
  alarm_name          = "${var.name_prefix}-neptune-cpu-high"
  alarm_description   = "Neptune cluster CPU utilization above 80%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/Neptune"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBClusterIdentifier = aws_neptune_cluster.main.cluster_identifier
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service = "neptune"
  })
}

resource "aws_cloudwatch_metric_alarm" "neptune_gremlin_errors" {
  alarm_name          = "${var.name_prefix}-neptune-gremlin-errors"
  alarm_description   = "Neptune Gremlin request errors above threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "GremlinErrors"
  namespace           = "AWS/Neptune"
  period              = 300
  statistic           = "Sum"
  threshold           = var.neptune_error_threshold

  dimensions = {
    DBClusterIdentifier = aws_neptune_cluster.main.cluster_identifier
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service = "neptune"
  })
}

resource "aws_cloudwatch_metric_alarm" "neptune_sparql_latency" {
  alarm_name          = "${var.name_prefix}-neptune-query-latency"
  alarm_description   = "Neptune query latency above 5 seconds (Requirement 10.3)"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "GremlinRequestsPerSec"
  namespace           = "AWS/Neptune"
  period              = 300
  statistic           = "Average"
  threshold           = 5000 # milliseconds

  dimensions = {
    DBClusterIdentifier = aws_neptune_cluster.main.cluster_identifier
  }

  alarm_actions = var.alarm_sns_topic_arns

  tags = merge(var.mandatory_tags, {
    Service = "neptune"
  })
}

# ---------------------------------------------------------
# IAM ROLE FOR NEPTUNE BULK LOADER (Requirement 10.2)
# ---------------------------------------------------------

resource "aws_iam_role" "neptune_loader" {
  name = "${var.name_prefix}-neptune-loader-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "neptune"
  })
}

resource "aws_iam_role_policy" "neptune_loader_s3" {
  name = "${var.name_prefix}-neptune-loader-s3"
  role = aws_iam_role.neptune_loader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadGoldLayer"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          var.gold_layer_bucket_arn,
          "${var.gold_layer_bucket_arn}/*",
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

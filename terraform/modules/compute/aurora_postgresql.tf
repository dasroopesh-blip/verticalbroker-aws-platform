# Aurora PostgreSQL - Transactional Ledger Database (Source of Truth)
# VerticalBroker AWS Data Engineering Platform
#
# This is the ACID-compliant relational database for the trading platform:
#   - Order/Wallet/Ledger truth (strong consistency)
#   - Source for DMS CDC pipeline → Bronze data lake
#   - Multi-AZ deployment for high availability
#   - Encrypted at rest (KMS) and in transit (TLS 1.3)
#
# Design rationale (from interview playbook):
#   "Use Aurora as ledger truth and events for downstream decoupling"
#   "Aurora for transactional order/ledger integrity and reconciliation"

# =============================================================================
# AURORA POSTGRESQL CLUSTER - Trading Ledger
# RTO 5-15 min, near-zero RPO (synchronous replication within region)
# =============================================================================

resource "aws_rds_cluster" "trading_ledger" {
  cluster_identifier = "${var.name_prefix}-trading-ledger"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"
  engine_mode        = "provisioned"

  database_name   = "verticalbroker"
  master_username = "vb_admin"
  manage_master_user_password = true # Secrets Manager auto-rotation

  # Storage
  storage_encrypted = true
  kms_key_id        = var.kms_confidential_key_arn
  storage_type      = "aurora-iopt1" # I/O Optimized for high-throughput trading

  # Networking (private subnets only)
  db_subnet_group_name   = aws_db_subnet_group.trading.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  # High Availability
  availability_zones = var.availability_zones

  # Backup & Recovery
  backup_retention_period      = 35 # Max retention for point-in-time recovery
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"
  copy_tags_to_snapshot        = true
  deletion_protection          = var.environment == "production"
  skip_final_snapshot          = var.environment != "production"
  final_snapshot_identifier    = var.environment == "production" ? "${var.name_prefix}-trading-ledger-final" : null

  # Performance Insights (for query analysis)
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_confidential_key_arn

  # Enhanced monitoring
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Serverless v2 scaling (auto-scales ACUs based on load)
  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity_acu
    max_capacity = var.aurora_max_capacity_acu
  }

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-trading-ledger"
    Service            = "aurora-postgresql"
    DataClassification = "Restricted"
    Purpose            = "transactional-ledger-source-of-truth"
    Compliance         = "FINRA-4511"
  })
}

# =============================================================================
# AURORA INSTANCES - Writer + 2 Readers
# Writer: handles all orders, wallet updates, ledger writes
# Readers: serve portfolio queries, reconciliation, reporting
# =============================================================================

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name_prefix}-trading-ledger-writer"
  cluster_identifier = aws_rds_cluster.trading_ledger.id
  instance_class     = "db.serverless" # Serverless v2
  engine             = "aurora-postgresql"
  engine_version     = aws_rds_cluster.trading_ledger.engine_version

  # Performance monitoring
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_confidential_key_arn
  monitoring_interval             = 15
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn

  # Auto minor version upgrade
  auto_minor_version_upgrade = true

  # Promotion priority (0 = highest priority for failover)
  promotion_tier = 0

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-trading-ledger-writer"
    Service = "aurora-postgresql"
    Role    = "writer"
  })
}

resource "aws_rds_cluster_instance" "readers" {
  count = var.aurora_reader_count

  identifier         = "${var.name_prefix}-trading-ledger-reader-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.trading_ledger.id
  instance_class     = "db.serverless" # Serverless v2
  engine             = "aurora-postgresql"
  engine_version     = aws_rds_cluster.trading_ledger.engine_version

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_confidential_key_arn
  monitoring_interval             = 15
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn

  auto_minor_version_upgrade = true
  promotion_tier             = count.index + 1

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-trading-ledger-reader-${count.index + 1}"
    Service = "aurora-postgresql"
    Role    = "reader"
  })
}

# =============================================================================
# SUBNET GROUP (private data subnets)
# =============================================================================

resource "aws_db_subnet_group" "trading" {
  name        = "${var.name_prefix}-trading-ledger-subnets"
  description = "Aurora PostgreSQL subnet group - private data subnets across 3 AZs"
  subnet_ids  = var.data_subnet_ids

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-trading-ledger-subnets"
    Service = "aurora-postgresql"
  })
}

# =============================================================================
# SECURITY GROUP - Aurora access from compute + DMS only
# =============================================================================

resource "aws_security_group" "aurora" {
  name_prefix = "${var.name_prefix}-aurora-"
  description = "Aurora PostgreSQL - allow access from compute Lambda and DMS only"
  vpc_id      = var.vpc_id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-aurora-sg"
    Service = "aurora-postgresql"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow PostgreSQL (5432) from compute subnets (Lambda functions)
resource "aws_security_group_rule" "aurora_ingress_compute" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = var.compute_subnet_cidrs
  security_group_id = aws_security_group.aurora.id
  description       = "PostgreSQL from compute subnets (Lambda Order Manager, Wallet Service)"
}

# Allow PostgreSQL (5432) from DMS replication instance
resource "aws_security_group_rule" "aurora_ingress_dms" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = var.dms_security_group_id
  security_group_id        = aws_security_group.aurora.id
  description              = "PostgreSQL from DMS replication instance (CDC pipeline)"
}

# =============================================================================
# IAM ROLE FOR ENHANCED MONITORING
# =============================================================================

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name_prefix}-aurora-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.mandatory_tags, {
    Service = "aurora-postgresql"
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# =============================================================================
# CLOUDWATCH ALARMS
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "aurora_cpu_high" {
  alarm_name          = "${var.name_prefix}-aurora-cpu-high"
  alarm_description   = "Aurora trading ledger CPU above 80% - may need scaling"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.trading_ledger.cluster_identifier
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, { Service = "aurora-postgresql" })
}

resource "aws_cloudwatch_metric_alarm" "aurora_connections_high" {
  alarm_name          = "${var.name_prefix}-aurora-connections-high"
  alarm_description   = "Aurora database connections above threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.aurora_max_connections_alarm

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.trading_ledger.cluster_identifier
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, { Service = "aurora-postgresql" })
}

# =============================================================================
# VARIABLES
# =============================================================================

variable "aurora_min_capacity_acu" {
  description = "Minimum Aurora Serverless v2 capacity (ACUs). 0.5 ACU = 1 GB RAM."
  type        = number
  default     = 2
}

variable "aurora_max_capacity_acu" {
  description = "Maximum Aurora Serverless v2 capacity (ACUs). 128 ACU max."
  type        = number
  default     = 64
}

variable "aurora_reader_count" {
  description = "Number of Aurora read replicas"
  type        = number
  default     = 2
}

variable "availability_zones" {
  description = "Availability zones for Aurora cluster"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "data_subnet_ids" {
  description = "Private data subnet IDs for Aurora deployment"
  type        = list(string)
  default     = []
}

variable "compute_subnet_cidrs" {
  description = "CIDR blocks of compute subnets allowed to access Aurora"
  type        = list(string)
  default     = []
}

variable "vpc_id" {
  description = "VPC ID for Aurora security group"
  type        = string
  default     = ""
}

variable "dms_security_group_id" {
  description = "Security group ID of the DMS replication instance (for CDC access)"
  type        = string
  default     = ""
}

variable "aurora_max_connections_alarm" {
  description = "Threshold for database connections alarm"
  type        = number
  default     = 500
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "aurora_cluster_endpoint" {
  description = "Aurora writer endpoint (for Order Manager and Wallet Service)"
  value       = aws_rds_cluster.trading_ledger.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint (for read queries and reconciliation)"
  value       = aws_rds_cluster.trading_ledger.reader_endpoint
}

output "aurora_cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.trading_ledger.arn
}

output "aurora_cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.trading_ledger.cluster_identifier
}

output "aurora_security_group_id" {
  description = "Security group ID for Aurora (pass to DMS for CDC access)"
  value       = aws_security_group.aurora.id
}

output "aurora_port" {
  description = "Aurora PostgreSQL port"
  value       = aws_rds_cluster.trading_ledger.port
}

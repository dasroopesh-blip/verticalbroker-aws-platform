# Security Groups Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Implements deny-by-default security groups with explicit allow rules.
# Security groups are organized by service tier to enforce least-privilege network access.
#
# Requirements: 20.6 (Network segmentation using Security Groups with deny-by-default rules
#               and explicit allow rules documented in Terraform)

# ---------------------------------------------------------
# DATA TIER SECURITY GROUP
# For: Glue jobs, DMS replication, S3 access, Lake Formation
# ---------------------------------------------------------

resource "aws_security_group" "data_tier" {
  name_prefix = "${var.name_prefix}-data-tier-"
  description = "Security group for data tier services (Glue, DMS, Lake Formation) - deny-by-default"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-data-tier"
    Tier    = "data"
    Purpose = "Data tier security group - Glue, DMS, Lake Formation"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow HTTPS outbound to VPC endpoints (S3, Glue, KMS)
resource "aws_security_group_rule" "data_tier_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.data_tier.id
  description       = "HTTPS to VPC endpoints for AWS service access"
}

# Allow self-referencing for Glue job inter-worker communication
resource "aws_security_group_rule" "data_tier_ingress_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_tier.id
  security_group_id        = aws_security_group.data_tier.id
  description              = "Self-referencing for Glue Spark worker communication"
}

resource "aws_security_group_rule" "data_tier_egress_self" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_tier.id
  security_group_id        = aws_security_group.data_tier.id
  description              = "Self-referencing egress for Glue Spark worker communication"
}

# ---------------------------------------------------------
# COMPUTE TIER SECURITY GROUP
# For: Lambda functions, Step Functions, API Gateway integrations
# ---------------------------------------------------------

resource "aws_security_group" "compute_tier" {
  name_prefix = "${var.name_prefix}-compute-tier-"
  description = "Security group for compute tier services (Lambda, Step Functions) - deny-by-default"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-compute-tier"
    Tier    = "compute"
    Purpose = "Compute tier security group - Lambda, Step Functions"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow HTTPS outbound to VPC endpoints (SQS, EventBridge, KMS, CloudWatch)
resource "aws_security_group_rule" "compute_tier_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.compute_tier.id
  description       = "HTTPS to VPC endpoints for AWS service access"
}

# Allow compute tier to access data tier (e.g., Lambda triggering Glue)
resource "aws_security_group_rule" "compute_tier_egress_to_data" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_tier.id
  security_group_id        = aws_security_group.compute_tier.id
  description              = "HTTPS to data tier services"
}

# ---------------------------------------------------------
# ANALYTICS TIER SECURITY GROUP
# For: OpenSearch, Neptune, Athena
# ---------------------------------------------------------

resource "aws_security_group" "analytics_tier" {
  name_prefix = "${var.name_prefix}-analytics-tier-"
  description = "Security group for analytics services (OpenSearch, Neptune, Athena) - deny-by-default"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-analytics-tier"
    Tier    = "analytics"
    Purpose = "Analytics tier security group - OpenSearch, Neptune, Athena"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow inbound HTTPS from compute tier (Lambda proxies querying analytics)
resource "aws_security_group_rule" "analytics_tier_ingress_compute_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.compute_tier.id
  security_group_id        = aws_security_group.analytics_tier.id
  description              = "HTTPS from compute tier for OpenSearch and Athena access"
}

# Allow inbound Gremlin (Neptune) from compute tier only
resource "aws_security_group_rule" "analytics_tier_ingress_neptune" {
  type                     = "ingress"
  from_port                = 8182
  to_port                  = 8182
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.compute_tier.id
  security_group_id        = aws_security_group.analytics_tier.id
  description              = "Gremlin (8182) from compute tier for Neptune graph queries"
}

# Allow outbound HTTPS for VPC endpoint communication
resource "aws_security_group_rule" "analytics_tier_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.analytics_tier.id
  description       = "HTTPS to VPC endpoints for AWS service access"
}

# ---------------------------------------------------------
# DATABASE TIER SECURITY GROUP
# For: DynamoDB (via VPC endpoint), Neptune cluster nodes
# ---------------------------------------------------------

resource "aws_security_group" "database_tier" {
  name_prefix = "${var.name_prefix}-database-tier-"
  description = "Security group for database services (Neptune cluster) - deny-by-default"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-database-tier"
    Tier    = "database"
    Purpose = "Database tier security group - Neptune"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow inbound Gremlin from analytics tier
resource "aws_security_group_rule" "database_tier_ingress_gremlin" {
  type                     = "ingress"
  from_port                = 8182
  to_port                  = 8182
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.analytics_tier.id
  security_group_id        = aws_security_group.database_tier.id
  description              = "Gremlin (8182) from analytics tier for Neptune access"
}

# Allow inbound from compute tier for direct Lambda-to-Neptune access
resource "aws_security_group_rule" "database_tier_ingress_compute" {
  type                     = "ingress"
  from_port                = 8182
  to_port                  = 8182
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.compute_tier.id
  security_group_id        = aws_security_group.database_tier.id
  description              = "Gremlin (8182) from compute tier for direct Lambda access"
}

# Allow outbound HTTPS for VPC endpoints (CloudWatch metrics, etc.)
resource "aws_security_group_rule" "database_tier_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.database_tier.id
  description       = "HTTPS to VPC endpoints for monitoring"
}

# ---------------------------------------------------------
# STREAMING TIER SECURITY GROUP
# For: Kinesis consumers, DMS replication instances
# ---------------------------------------------------------

resource "aws_security_group" "streaming_tier" {
  name_prefix = "${var.name_prefix}-streaming-tier-"
  description = "Security group for streaming services (Kinesis, DMS) - deny-by-default"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-streaming-tier"
    Tier    = "streaming"
    Purpose = "Streaming tier security group - Kinesis consumers, DMS"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow inbound from data tier (DMS replication instances communicate internally)
resource "aws_security_group_rule" "streaming_tier_ingress_data" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_tier.id
  security_group_id        = aws_security_group.streaming_tier.id
  description              = "HTTPS from data tier for DMS replication"
}

# Allow outbound HTTPS to VPC endpoints
resource "aws_security_group_rule" "streaming_tier_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.streaming_tier.id
  description       = "HTTPS to VPC endpoints for AWS service access"
}

# Allow outbound to data tier (writing to S3 via data subnets)
resource "aws_security_group_rule" "streaming_tier_egress_to_data" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_tier.id
  security_group_id        = aws_security_group.streaming_tier.id
  description              = "HTTPS to data tier for S3 write operations"
}

# ---------------------------------------------------------
# ML TIER SECURITY GROUP
# For: SageMaker endpoints, training instances
# ---------------------------------------------------------

resource "aws_security_group" "ml_tier" {
  name_prefix = "${var.name_prefix}-ml-tier-"
  description = "Security group for ML services (SageMaker) - deny-by-default"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-ml-tier"
    Tier    = "ml"
    Purpose = "ML tier security group - SageMaker training and inference"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow inbound from compute tier (Lambda invoking SageMaker endpoints)
resource "aws_security_group_rule" "ml_tier_ingress_compute" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.compute_tier.id
  security_group_id        = aws_security_group.ml_tier.id
  description              = "HTTPS from compute tier for SageMaker endpoint invocation"
}

# Allow SageMaker inter-node communication for distributed training
resource "aws_security_group_rule" "ml_tier_ingress_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ml_tier.id
  security_group_id        = aws_security_group.ml_tier.id
  description              = "Self-referencing for SageMaker distributed training"
}

resource "aws_security_group_rule" "ml_tier_egress_self" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ml_tier.id
  security_group_id        = aws_security_group.ml_tier.id
  description              = "Self-referencing egress for SageMaker distributed training"
}

# Allow outbound HTTPS for VPC endpoints (S3 for model artifacts, KMS for encryption)
resource "aws_security_group_rule" "ml_tier_egress_https_vpc" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.ml_tier.id
  description       = "HTTPS to VPC endpoints for S3 and KMS access"
}

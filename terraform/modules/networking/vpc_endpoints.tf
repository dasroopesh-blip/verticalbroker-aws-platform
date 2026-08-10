# VPC Endpoints Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Implements VPC endpoints for private AWS service access:
# - Gateway Endpoint: S3
# - Interface Endpoints: Glue, KMS, SQS, EventBridge, CloudWatch
# - PrivateLink: API Gateway (execute-api)
#
# Requirements: 20.3 (Private subnets, VPC Endpoints for AWS service connectivity)
#               20.4 (PrivateLink for API Gateway private access)
#               16.1 (All resources in private subnets)

# ---------------------------------------------------------
# SECURITY GROUP FOR VPC ENDPOINTS
# All interface endpoints share a common security group
# ---------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name_prefix = "${var.name_prefix}-vpce-"
  description = "Security group for VPC Interface Endpoints - allows HTTPS from VPC"
  vpc_id      = aws_vpc.main.id

  # Allow HTTPS inbound from the entire VPC CIDR
  ingress {
    description = "HTTPS from VPC for AWS service API calls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # No outbound rules needed - endpoints are targets, not initiators
  egress {
    description = "Allow responses back to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-vpc-endpoints"
    Purpose = "Security group for VPC Interface Endpoints"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------
# S3 GATEWAY ENDPOINT
# Gateway endpoint for S3 access (no data transfer charges)
# Required for: Bronze/Silver/Gold layer access, Terraform state, logs
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  # Associate with both data and compute route tables
  route_table_ids = [
    aws_route_table.data.id,
    aws_route_table.compute.id,
  ]

  # Restrictive policy - only allow access to platform buckets
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPlatformBucketAccess"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          "arn:aws:s3:::${var.platform_name}-*",
          "arn:aws:s3:::${var.platform_name}-*/*"
        ]
      },
      {
        Sid       = "AllowGlueCatalogBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-glue-*",
          "arn:aws:s3:::aws-glue-*/*"
        ]
      }
    ]
  })

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-s3"
    Purpose = "S3 Gateway VPC Endpoint for private data lake access"
    Type    = "Gateway"
  })
}

# ---------------------------------------------------------
# GLUE INTERFACE ENDPOINT
# Required for: ETL jobs, Data Catalog access, Crawlers
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "glue" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.glue"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = aws_subnet.data[*].id

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-glue"
    Purpose = "Glue Interface VPC Endpoint for ETL and Data Catalog"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# KMS INTERFACE ENDPOINT
# Required for: Encryption/decryption of all data at rest
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "kms" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.kms"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = concat(
    aws_subnet.data[*].id,
    aws_subnet.compute[*].id
  )

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-kms"
    Purpose = "KMS Interface VPC Endpoint for encryption operations"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# SQS INTERFACE ENDPOINT
# Required for: Message queues, DLQs, trade processing FIFO
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "sqs" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sqs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = aws_subnet.compute[*].id

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-sqs"
    Purpose = "SQS Interface VPC Endpoint for message queue access"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# EVENTBRIDGE INTERFACE ENDPOINT
# Required for: Event bus communication between services
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "events" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.events"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = aws_subnet.compute[*].id

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-eventbridge"
    Purpose = "EventBridge Interface VPC Endpoint for event routing"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH LOGS INTERFACE ENDPOINT
# Required for: Centralized logging from all services
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "logs" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = concat(
    aws_subnet.data[*].id,
    aws_subnet.compute[*].id
  )

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-cloudwatch-logs"
    Purpose = "CloudWatch Logs Interface VPC Endpoint for log delivery"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH MONITORING INTERFACE ENDPOINT
# Required for: Metrics, alarms, dashboards
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "monitoring" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.monitoring"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = aws_subnet.compute[*].id

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-cloudwatch-monitoring"
    Purpose = "CloudWatch Monitoring Interface VPC Endpoint for metrics"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# API GATEWAY EXECUTE-API PRIVATELINK ENDPOINT
# Enables private API access without traversing public internet
# Requirement 20.4: PrivateLink for API Gateway private access
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "execute_api" {
  count = var.enable_privatelink_api_gateway ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.execute-api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = aws_subnet.compute[*].id

  security_group_ids = [aws_security_group.api_gateway_endpoint[0].id]

  # Policy restricting access to platform APIs only
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPlatformAPIs"
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "arn:aws:execute-api:${data.aws_region.current.name}:*:*"
      }
    ]
  })

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-execute-api"
    Purpose = "API Gateway PrivateLink for private API access"
    Type    = "Interface"
  })
}

# ---------------------------------------------------------
# API GATEWAY ENDPOINT SECURITY GROUP
# Separate security group with more restrictive rules for API access
# ---------------------------------------------------------

resource "aws_security_group" "api_gateway_endpoint" {
  count = var.enable_privatelink_api_gateway ? 1 : 0

  name_prefix = "${var.name_prefix}-vpce-apigw-"
  description = "Security group for API Gateway VPC Endpoint - HTTPS from compute subnets"
  vpc_id      = aws_vpc.main.id

  # Allow HTTPS from compute subnets only (not all VPC)
  ingress {
    description = "HTTPS from compute subnets for API calls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.compute_subnet_cidrs
  }

  # Allow responses back
  egress {
    description = "Allow responses to compute subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.compute_subnet_cidrs
  }

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-sg-vpce-api-gateway"
    Purpose = "Security group for API Gateway PrivateLink endpoint"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------
# ADDITIONAL INTERFACE ENDPOINTS
# DynamoDB, STS, Lambda for full private connectivity
# ---------------------------------------------------------

resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.data.id,
    aws_route_table.compute.id,
  ]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-dynamodb"
    Purpose = "DynamoDB Gateway VPC Endpoint for idempotency and state stores"
    Type    = "Gateway"
  })
}

resource "aws_vpc_endpoint" "sts" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = aws_subnet.compute[*].id

  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-vpce-sts"
    Purpose = "STS Interface VPC Endpoint for IAM role assumption"
    Type    = "Interface"
  })
}

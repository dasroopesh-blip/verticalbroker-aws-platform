# IAM Roles - Least Privilege Service Roles
# VerticalBroker AWS Data Engineering Platform
# Requirements: 14.3 (Least-privilege IAM), 13.4 (No wildcard resource permissions)
# Requirements: 20.5 (Baseline security controls)
#
# Roles:
# - MarketDataLambdaRole: Market data ingestion from Kinesis to Bronze S3
# - ETLGlueRole: Glue PySpark jobs for Bronze→Silver→Gold transformations
# - AdvisoryAgentRole: ML advisory service invoking SageMaker + regulatory logging
# - OrderManagerRole: Order processing with DynamoDB, EventBridge, SQS
# - WalletServiceRole: Portfolio management with DynamoDB, SQS trade processing

# ---------------------------------------------------------
# DATA SOURCES
# ---------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------
# PERMISSION BOUNDARY
# Applied to ALL roles to constrain maximum permissions
# Requirement 14.3: Permission boundaries constraining maximum permissions per role
# ---------------------------------------------------------

resource "aws_iam_policy" "permission_boundary" {
  name        = "${var.platform_name}-permission-boundary-${var.environment}"
  description = "Permission boundary constraining maximum permissions for all platform roles"
  path        = "/verticalbroker/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSpecificServices"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:DeleteObject",
          "s3:ListBucket",
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "glue:GetTable",
          "glue:GetDatabase",
          "glue:UpdatePartition",
          "glue:BatchCreatePartition",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
          "glue:CreatePartition",
          "glue:DeletePartition",
          "events:PutEvents",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:Encrypt",
          "sagemaker:InvokeEndpoint",
          "ssm:GetParameter",
          "ssm:GetParametersByPath",
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyIAMModification"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:PutRolePermissionsBoundary",
          "iam:DeleteRolePermissionsBoundary"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyOrganizationsModification"
        Effect = "Deny"
        Action = [
          "organizations:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyCloudTrailModification"
        Effect = "Deny"
        Action = [
          "cloudtrail:DeleteTrail",
          "cloudtrail:StopLogging",
          "cloudtrail:UpdateTrail"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyKMSKeyDeletion"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion",
          "kms:DisableKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "security"
    Name    = "${var.platform_name}-permission-boundary-${var.environment}"
  })
}

# ---------------------------------------------------------
# MARKET DATA LAMBDA ROLE
# Purpose: Ingest market data from Kinesis → S3 Bronze
# Trust: lambda.amazonaws.com
# ---------------------------------------------------------

resource "aws_iam_role" "market_data_lambda" {
  name                 = "${var.platform_name}-market-data-lambda-${var.environment}"
  path                 = "/verticalbroker/"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaAssume"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "market-data-ingestion"
    Name    = "${var.platform_name}-market-data-lambda-${var.environment}"
  })
}

# ---------------------------------------------------------
# ETL GLUE ROLE
# Purpose: Execute PySpark ETL jobs (Bronze→Silver→Gold)
# Trust: glue.amazonaws.com
# ---------------------------------------------------------

resource "aws_iam_role" "etl_glue" {
  name                 = "${var.platform_name}-etl-glue-${var.environment}"
  path                 = "/verticalbroker/"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGlueAssume"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "etl-pipeline"
    Name    = "${var.platform_name}-etl-glue-${var.environment}"
  })
}

# ---------------------------------------------------------
# ADVISORY AGENT ROLE
# Purpose: ML advisory service (SageMaker invoke + regulatory logging)
# Trust: lambda.amazonaws.com
# ---------------------------------------------------------

resource "aws_iam_role" "advisory_agent" {
  name                 = "${var.platform_name}-advisory-agent-${var.environment}"
  path                 = "/verticalbroker/"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaAssume"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "advisory-agent"
    Name    = "${var.platform_name}-advisory-agent-${var.environment}"
  })
}

# ---------------------------------------------------------
# ORDER MANAGER ROLE
# Purpose: Order processing (DynamoDB, EventBridge, SQS)
# Trust: lambda.amazonaws.com
# ---------------------------------------------------------

resource "aws_iam_role" "order_manager" {
  name                 = "${var.platform_name}-order-manager-${var.environment}"
  path                 = "/verticalbroker/"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaAssume"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "order-manager"
    Name    = "${var.platform_name}-order-manager-${var.environment}"
  })
}

# ---------------------------------------------------------
# WALLET SERVICE ROLE
# Purpose: Portfolio management (DynamoDB read/write, SQS trade processing)
# Trust: lambda.amazonaws.com
# ---------------------------------------------------------

resource "aws_iam_role" "wallet_service" {
  name                 = "${var.platform_name}-wallet-service-${var.environment}"
  path                 = "/verticalbroker/"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaAssume"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "wallet-service"
    Name    = "${var.platform_name}-wallet-service-${var.environment}"
  })
}

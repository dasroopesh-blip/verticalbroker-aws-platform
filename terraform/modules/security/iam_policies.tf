# IAM Policies - Least Privilege Service Policies
# VerticalBroker AWS Data Engineering Platform
# Requirements: 14.3 (Least-privilege IAM with specific resource ARNs)
# Requirements: 13.4 (No wildcard resource permissions in production)
# Requirements: 20.5 (Baseline security controls)
#
# Policies implemented from design:
# - MARKET_DATA_LAMBDA_POLICY: Kinesis read, S3 Bronze write, Glue catalog, EventBridge, SQS DLQ, KMS, DynamoDB
# - ETL_GLUE_ROLE_POLICY: S3 read Bronze/Silver, write Silver/Gold, Glue catalog, CloudWatch logs
# - ADVISORY_AGENT_POLICY: SageMaker invoke, Regulatory Store write (Object Lock), Parameter Store read
# - ORDER_MANAGER_POLICY: DynamoDB, EventBridge, SQS, KMS, CloudWatch logs
# - WALLET_SERVICE_POLICY: DynamoDB read/write portfolio, SQS trade-processing queue

# ---------------------------------------------------------
# MARKET DATA LAMBDA POLICY
# Allows: Kinesis read, S3 Bronze write, Glue partition update,
#         EventBridge publish, SQS DLQ write, KMS, DynamoDB idempotency
# ---------------------------------------------------------

resource "aws_iam_policy" "market_data_lambda" {
  name        = "${var.platform_name}-market-data-lambda-policy-${var.environment}"
  description = "Least-privilege policy for Market Data Ingestion Lambda"
  path        = "/verticalbroker/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KinesisRead"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:kinesis:${var.aws_region}:${var.aws_account_id}:stream/${var.kinesis_market_data_stream_name}-*"
      },
      {
        Sid    = "S3BronzeWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::vb-bronze-${var.environment}/*"
      },
      {
        Sid    = "GlueCatalogUpdate"
        Effect = "Allow"
        Action = [
          "glue:UpdatePartition",
          "glue:BatchCreatePartition"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:database/verticalbroker_bronze",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:table/verticalbroker_bronze/*"
        ]
      },
      {
        Sid    = "EventBridgePut"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${var.aws_account_id}:event-bus/${var.eventbridge_bus_name}"
      },
      {
        Sid    = "SQSDLQWrite"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${var.aws_account_id}:market-data-dlq"
      },
      {
        Sid    = "KMSDecryptEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_bronze_key_arn
      },
      {
        Sid    = "DynamoDBIdempotency"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/IdempotencyStore"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.platform_name}-market-data-*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:xray:${var.aws_region}:${var.aws_account_id}:group/${var.platform_name}-market-data/*"
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "market-data-ingestion"
    Name    = "${var.platform_name}-market-data-lambda-policy-${var.environment}"
  })
}

resource "aws_iam_role_policy_attachment" "market_data_lambda" {
  role       = aws_iam_role.market_data_lambda.name
  policy_arn = aws_iam_policy.market_data_lambda.arn
}

# ---------------------------------------------------------
# ETL GLUE ROLE POLICY
# Allows: S3 read Bronze/Silver, S3 write Silver/Gold,
#         Glue catalog operations, CloudWatch logs, KMS
# ---------------------------------------------------------

resource "aws_iam_policy" "etl_glue" {
  name        = "${var.platform_name}-etl-glue-policy-${var.environment}"
  description = "Least-privilege policy for ETL Glue PySpark jobs"
  path        = "/verticalbroker/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadBronzeSilver"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::vb-bronze-${var.environment}",
          "arn:${data.aws_partition.current.partition}:s3:::vb-bronze-${var.environment}/*",
          "arn:${data.aws_partition.current.partition}:s3:::vb-silver-${var.environment}",
          "arn:${data.aws_partition.current.partition}:s3:::vb-silver-${var.environment}/*"
        ]
      },
      {
        Sid    = "S3WriteSilverGold"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::vb-silver-${var.environment}/*",
          "arn:${data.aws_partition.current.partition}:s3:::vb-gold-${var.environment}/*"
        ]
      },
      {
        Sid    = "GlueCatalogFull"
        Effect = "Allow"
        Action = [
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
          "glue:CreatePartition",
          "glue:BatchCreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:GetTable",
          "glue:GetDatabase"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:database/verticalbroker_bronze",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:database/verticalbroker_silver",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:database/verticalbroker_gold",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:table/verticalbroker_bronze/*",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:table/verticalbroker_silver/*",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${var.aws_account_id}:table/verticalbroker_gold/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws-glue/${var.platform_name}-*"
      },
      {
        Sid    = "KMSDecryptEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:Encrypt"
        ]
        Resource = [
          var.kms_bronze_key_arn,
          var.kms_silver_key_arn,
          var.kms_gold_key_arn
        ]
      },
      {
        Sid    = "EventBridgePut"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${var.aws_account_id}:event-bus/${var.eventbridge_bus_name}"
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "etl-pipeline"
    Name    = "${var.platform_name}-etl-glue-policy-${var.environment}"
  })
}

resource "aws_iam_role_policy_attachment" "etl_glue" {
  role       = aws_iam_role.etl_glue.name
  policy_arn = aws_iam_policy.etl_glue.arn
}

# ---------------------------------------------------------
# ADVISORY AGENT POLICY
# Allows: SageMaker endpoint invoke, Regulatory Store S3 write
#         (with Object Lock condition), Parameter Store read, KMS, logs
# ---------------------------------------------------------

resource "aws_iam_policy" "advisory_agent" {
  name        = "${var.platform_name}-advisory-agent-policy-${var.environment}"
  description = "Least-privilege policy for Advisory Agent Lambda"
  path        = "/verticalbroker/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SageMakerInvoke"
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sagemaker:${var.aws_region}:${var.aws_account_id}:endpoint/${var.sagemaker_advisory_endpoint_prefix}-*"
      },
      {
        Sid    = "RegulatoryStoreWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::vb-regulatory-store-${var.environment}/advisory-logs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-object-lock-mode" = "COMPLIANCE"
          }
        }
      },
      {
        Sid    = "ParameterStoreRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${var.aws_account_id}:parameter/verticalbroker/advisory/*"
      },
      {
        Sid    = "KMSDecryptEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_restricted_key_arn
      },
      {
        Sid    = "DynamoDBIdempotency"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/IdempotencyStore"
      },
      {
        Sid    = "EventBridgePut"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${var.aws_account_id}:event-bus/${var.eventbridge_bus_name}"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.platform_name}-advisory-*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:xray:${var.aws_region}:${var.aws_account_id}:group/${var.platform_name}-advisory/*"
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "advisory-agent"
    Name    = "${var.platform_name}-advisory-agent-policy-${var.environment}"
  })
}

resource "aws_iam_role_policy_attachment" "advisory_agent" {
  role       = aws_iam_role.advisory_agent.name
  policy_arn = aws_iam_policy.advisory_agent.arn
}

# ---------------------------------------------------------
# ORDER MANAGER POLICY
# Allows: DynamoDB (orders + idempotency), EventBridge publish,
#         SQS send, KMS, CloudWatch logs
# ---------------------------------------------------------

resource "aws_iam_policy" "order_manager" {
  name        = "${var.platform_name}-order-manager-policy-${var.environment}"
  description = "Least-privilege policy for Order Manager Lambda"
  path        = "/verticalbroker/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBOrdersReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/Orders",
          "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/Orders/index/*"
        ]
      },
      {
        Sid    = "DynamoDBIdempotency"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/IdempotencyStore"
      },
      {
        Sid    = "EventBridgePut"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${var.aws_account_id}:event-bus/${var.eventbridge_bus_name}"
      },
      {
        Sid    = "SQSSendTradeEvents"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${var.aws_account_id}:trade-processing.fifo"
      },
      {
        Sid    = "SQSDLQWrite"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${var.aws_account_id}:order-manager-dlq"
      },
      {
        Sid    = "KMSDecryptEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_gold_key_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.platform_name}-order-manager-*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:xray:${var.aws_region}:${var.aws_account_id}:group/${var.platform_name}-order-manager/*"
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "order-manager"
    Name    = "${var.platform_name}-order-manager-policy-${var.environment}"
  })
}

resource "aws_iam_role_policy_attachment" "order_manager" {
  role       = aws_iam_role.order_manager.name
  policy_arn = aws_iam_policy.order_manager.arn
}

# ---------------------------------------------------------
# WALLET SERVICE POLICY
# Allows: DynamoDB read/write for portfolio, SQS read from
#         trade-processing queue, KMS, CloudWatch logs
# ---------------------------------------------------------

resource "aws_iam_policy" "wallet_service" {
  name        = "${var.platform_name}-wallet-service-policy-${var.environment}"
  description = "Least-privilege policy for Wallet Service Lambda"
  path        = "/verticalbroker/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBPortfolioReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/Portfolio",
          "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${var.aws_account_id}:table/Portfolio/index/*"
        ]
      },
      {
        Sid    = "SQSTradeProcessingRead"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${var.aws_account_id}:trade-processing.fifo"
      },
      {
        Sid    = "SQSDLQWrite"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${var.aws_account_id}:wallet-service-dlq"
      },
      {
        Sid    = "KMSDecryptEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_gold_key_arn
      },
      {
        Sid    = "EventBridgePut"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${var.aws_account_id}:event-bus/${var.eventbridge_bus_name}"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${var.platform_name}-wallet-service-*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:xray:${var.aws_region}:${var.aws_account_id}:group/${var.platform_name}-wallet-service/*"
      }
    ]
  })

  tags = merge(var.tags, {
    Service = "wallet-service"
    Name    = "${var.platform_name}-wallet-service-policy-${var.environment}"
  })
}

resource "aws_iam_role_policy_attachment" "wallet_service" {
  role       = aws_iam_role.wallet_service.name
  policy_arn = aws_iam_policy.wallet_service.arn
}

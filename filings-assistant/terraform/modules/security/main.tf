# ===========================================================================
# Security module: KMS encryption key + IAM role/policies for the worker.
#
# LEARNING NOTE: IAM (Identity and Access Management) controls *who can do what*.
# The worker Lambda gets a ROLE, and the role has POLICIES granting least-
# privilege access: read SQS, call the two specific Bedrock models, and write
# to OpenSearch. We scope Bedrock to the exact model ARNs — no wildcards — which
# is both a project convention and a security best practice.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "bedrock_reasoning_model_id" {
  type = string
}

variable "bedrock_embedding_model_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}

# --- KMS key: encrypts data at rest (SQS, RDS, OpenSearch) ------------------
resource "aws_kms_key" "this" {
  description         = "${var.name_prefix} encryption key"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.this.key_id
}

# --- Lambda execution role --------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

# Managed policy for CloudWatch Logs + VPC networking (ENI create/delete).
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Inline least-privilege policy: Bedrock (2 specific models), SQS, KMS.
data "aws_iam_policy_document" "worker" {
  statement {
    sid     = "InvokeBedrockModels"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_reasoning_model_id}",
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_embedding_model_id}",
    ]
  }

  statement {
    sid       = "ConsumeIngestQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = ["arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"]
  }

  statement {
    sid       = "UseKmsKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.this.arn]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "${var.name_prefix}-worker-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.worker.json
}

# --- SageMaker execution role (for the reranker endpoint) -------------------
# SageMaker assumes this role to pull the model artifact from S3 and the
# inference image from ECR, and to write logs. Scoped to the managed
# SageMaker policy + KMS use; tighten the S3/ECR resources for production.
data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name               = "${var.name_prefix}-sagemaker-role"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# Allow the WORKER (which invokes reranking) to call the SageMaker endpoint.
data "aws_iam_policy_document" "invoke_reranker" {
  statement {
    sid       = "InvokeSageMakerReranker"
    actions   = ["sagemaker:InvokeEndpoint"]
    resources = ["arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${var.name_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "invoke_reranker" {
  name   = "${var.name_prefix}-invoke-reranker"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.invoke_reranker.json
}

output "kms_key_arn" {
  value = aws_kms_key.this.arn
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker.arn
}

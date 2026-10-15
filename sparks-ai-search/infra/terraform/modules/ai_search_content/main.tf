###############################################################################
# module: ai_search_content
# Purpose: the READ-ONLY extraction path + the S3 bucket that holds the curated
#          AI search content (one JSON object per uniqueId). This is the only place that
#          touches SPARKS data, and it only READS the outbox.
#
# Resources this module owns (fill in when FED approves spend):
#   - aws_kms_key                : CMK to encrypt the search content bucket + logs
#   - aws_s3_bucket              : sparks-ai-search-content-<env> (versioned, SSE-KMS, no public)
#   - aws_s3_bucket_versioning   : keep history (enables rebuild/replay)
#   - aws_s3_bucket_public_access_block : block ALL public access
#   - aws_lambda_function        : "extractor" (reads outbox read-only -> writes S3)
#   - aws_iam_role / policy      : LEAST-PRIVILEGE: SELECT outbox + PutObject search content only
#   - aws_cloudwatch_event_rule  : refresh_schedule trigger
#   - aws_sqs_queue              : DLQ for failed extraction runs
#   - aws_ssm_parameter          : watermark (osj_update_dt high-water mark)
#   - VPC config on the Lambda   : runs in private subnets, no public egress
#
# Beginner note: we expose only a few INPUTS (below) and a few OUTPUTS so the
# root module can wire things without knowing the internals.
###############################################################################

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "sparks_db_secret_arn" { type = string }
variable "outbox_read_sql" { type = string }
variable "refresh_schedule" { type = string }

# --- OUTPUTS (consumed by bedrock_rag) --------------------------------------
output "bucket_name" {
  description = "Name of the curated search content S3 bucket."
  value       = "${var.name_prefix}-search-content" # placeholder; real value = aws_s3_bucket.search_content.id
}

output "bucket_arn" {
  description = "ARN of the search content bucket (Bedrock KB reads from here)."
  value       = "arn:aws:s3:::${var.name_prefix}-search-content" # placeholder
}

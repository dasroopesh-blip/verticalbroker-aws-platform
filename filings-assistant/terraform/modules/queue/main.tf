# ===========================================================================
# Queue module: SQS ingest queue + dead-letter queue (DLQ).
#
# LEARNING NOTE: The main queue holds "index this filing" jobs. If the worker
# fails to process a message repeatedly (maxReceiveCount), SQS moves it to the
# DLQ instead of retrying forever. That quarantines "poison" messages so one
# bad filing can't block the pipeline — a core resilience pattern.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Dead-letter queue: where messages go after too many failed attempts.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-ingest-dlq"
  message_retention_seconds = 1209600 # 14 days, to allow investigation
  kms_master_key_id         = var.kms_key_arn
  tags                      = var.tags
}

# Main ingest queue. Visibility timeout is 6x the Lambda timeout to avoid a
# message becoming visible again (and double-processed) while still in flight.
resource "aws_sqs_queue" "ingest" {
  name                       = "${var.name_prefix}-ingest"
  visibility_timeout_seconds = 180 # 6 x the 30s worker timeout
  message_retention_seconds  = 345600 # 4 days
  kms_master_key_id          = var.kms_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })

  tags = var.tags
}

output "queue_url" {
  value = aws_sqs_queue.ingest.url
}

output "queue_arn" {
  value = aws_sqs_queue.ingest.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

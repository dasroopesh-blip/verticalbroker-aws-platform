# ---------------------------------------------------------------------------
# Root outputs — values printed after `apply` and usable by other tooling.
# LEARNING NOTE: outputs expose selected values from your modules (e.g. the
# OpenSearch endpoint) so you can wire them into app config or scripts.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "The VPC ID."
  value       = module.networking.vpc_id
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint (set as FA_OPENSEARCH_HOST)."
  value       = module.search.endpoint
}

output "postgres_endpoint" {
  description = "RDS Postgres connection endpoint (set as FA_PG_HOST)."
  value       = module.database.endpoint
}

output "ingest_queue_url" {
  description = "SQS ingest queue URL (set as FA_QUEUE_URL)."
  value       = module.queue.queue_url
}

output "worker_lambda_name" {
  description = "Name of the indexing worker Lambda."
  value       = module.compute.worker_function_name
}

output "reranker_endpoint_name" {
  description = "SageMaker reranker endpoint name (empty if reranker disabled)."
  value       = var.enable_reranker ? module.reranker[0].endpoint_name : ""
}

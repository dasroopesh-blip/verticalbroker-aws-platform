###############################################################################
# outputs.tf (Dev) — useful values after apply. Run `terraform output` to see them.
###############################################################################

output "ask_api_url" {
  description = "Invoke URL for the /ask endpoint (wire this into the Ask SPARKS chat box)."
  value       = module.ask_api.invoke_url
}

output "content_bucket" {
  description = "S3 bucket holding the curated AI search content."
  value       = module.ai_search_content.bucket_name
}

output "vector_collection" {
  description = "OpenSearch Serverless vector collection endpoint."
  value       = module.vector_index.collection_endpoint
}

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base id (Option 1 retrieval)."
  value       = module.bedrock_rag.knowledge_base_id
}

output "agent_enabled" {
  description = "Whether Option 2 (Agentic) was deployed."
  value       = var.enable_agent
}

output "dashboard_url" {
  description = "CloudWatch dashboard for latency/tokens/cost/freshness."
  value       = module.observability.dashboard_url
}

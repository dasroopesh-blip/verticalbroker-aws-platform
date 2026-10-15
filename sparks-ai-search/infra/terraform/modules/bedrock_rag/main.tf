###############################################################################
# module: bedrock_rag  (Option 1 core)
# Purpose: an Amazon Bedrock Knowledge Base that ingests the S3 search content, chunks +
#          embeds it with Titan, and stores vectors in the AOSS collection.
#          This is the managed retrieval layer for RAG.
#
# Resources this module owns (fill in when approved):
#   - aws_iam_role (KB service role): read search content bucket + write AOSS + invoke embed model
#   - aws_bedrockagent_knowledge_base:
#        storage_configuration -> OpenSearch Serverless (collection_arn, vector field,
#                                 metadata fields incl. uniqueId)
#        embedding model       -> var.bedrock_embedding_model_id
#   - aws_bedrockagent_data_source: the S3 search content bucket (+ chunking config)
#   - S3 event -> EventBridge -> StartIngestionJob (event-driven re-sync on search content change)
###############################################################################

variable "name_prefix" { type = string }
variable "content_bucket_arn" { type = string }
variable "vector_collection_arn" { type = string }
variable "bedrock_embedding_model_id" { type = string }

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base id used by the Ask API (and the agent's semanticSearch tool)."
  value       = "${var.name_prefix}-kb" # placeholder; real = aws_bedrockagent_knowledge_base.this.id
}

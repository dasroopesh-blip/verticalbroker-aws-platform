###############################################################################
# module: vector_index
# Purpose: the vector store for semantic search — an Amazon OpenSearch Serverless
#          (AOSS) VECTOR collection, kept SEPARATE from the production sparks-stage
#          search domain so AI load never affects the existing search.
#
# Why AOSS (not pgvector on prod RDS): isolates AI load, native k-NN + metadata
# filters, serverless scaling. (See PRODUCTION_DESIGN §0.)
#
# Resources this module owns (fill in when approved):
#   - aws_opensearchserverless_security_policy (encryption, KMS)
#   - aws_opensearchserverless_security_policy (network: VPC-only, private)
#   - aws_opensearchserverless_access_policy   (data access for KB + tools role)
#   - aws_opensearchserverless_collection      (type = VECTORSEARCH)
#   - aws_opensearchserverless_vpc_endpoint    (private connectivity)
#   - vector index mapping: embedding (knn_vector, dim per Titan v2),
#       + metadata fields: uniqueId (keyword), domain (keyword), facets, dates
###############################################################################

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

output "collection_arn" {
  description = "ARN of the AOSS vector collection (Bedrock KB targets this)."
  value       = "arn:aws:aoss:::collection/${var.name_prefix}-vec" # placeholder
}

output "collection_endpoint" {
  description = "HTTPS endpoint of the vector collection."
  value       = "https://${var.name_prefix}-vec.aoss.local" # placeholder
}

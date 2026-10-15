###############################################################################
# main.tf (Dev) — wires the building-block modules together.
#
# Read top-to-bottom, it IS the architecture:
#   search content (S3)  ->  vector index (AOSS)  ->  RAG (Bedrock KB)  ->  Ask API
#                                                          \-> Agent (optional, Opt 3)
#   observability wraps everything (dashboard, alarms, budget).
#
# NOTE: module internals are intentionally stubbed in this skeleton (resources are
# described in comments) so the team can review the SHAPE and wiring before any
# apply. Fill in the resource blocks when FED approves Dev spend.
###############################################################################

locals {
  name_prefix = "sparks-ai-${var.env}"
}

# 1) Curated AI search content bucket (S3, KMS, versioned). Read-only extractor writes here.
module "ai_search_content" {
  source      = "../../modules/ai_search_content"
  name_prefix = local.name_prefix

  vpc_id               = var.vpc_id
  private_subnet_ids   = var.private_subnet_ids
  sparks_db_secret_arn = var.sparks_db_secret_arn
  outbox_read_sql      = var.outbox_read_sql
  refresh_schedule     = var.refresh_schedule
}

# 2) Vector store: OpenSearch Serverless vector collection (separate from sparks-stage).
module "vector_index" {
  source      = "../../modules/vector_index"
  name_prefix = local.name_prefix

  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
}

# 3) Option 1 (RAG): Bedrock Knowledge Base over the search content, embedding into the vector store.
module "bedrock_rag" {
  source      = "../../modules/bedrock_rag"
  name_prefix = local.name_prefix

  content_bucket_arn          = module.ai_search_content.bucket_arn
  vector_collection_arn      = module.vector_index.collection_arn
  bedrock_embedding_model_id = var.bedrock_embedding_model_id
}

# 4) The /ask API: API Gateway (private) + Ask Lambda. Option 1 by default.
module "ask_api" {
  source      = "../../modules/ask_api"
  name_prefix = local.name_prefix

  vpc_id                  = var.vpc_id
  private_subnet_ids      = var.private_subnet_ids
  knowledge_base_id       = module.bedrock_rag.knowledge_base_id
  bedrock_answer_model_id = var.bedrock_answer_model_id
  bedrock_cheap_model_id  = var.bedrock_cheap_model_id
  top_k                   = var.top_k
  enable_agent            = var.enable_agent
  agent_id                = var.enable_agent ? module.agent[0].agent_id : null
}

# 5) Option 2 (Agentic): Bedrock Agent + approved tool Lambdas. Only when enabled.
module "agent" {
  source = "../../modules/agent"
  count  = var.enable_agent ? 1 : 0

  name_prefix          = local.name_prefix
  knowledge_base_id    = module.bedrock_rag.knowledge_base_id
  sparks_db_secret_arn = var.sparks_db_secret_arn        # read-only views only
  existing_opensearch  = "sparks-stage"                  # reused as a tool, unchanged
  max_tool_calls       = var.agent_max_tool_calls
  answer_model_id      = var.bedrock_answer_model_id
}

# 6) Observability: dashboard, alarms, and the hard cost cap.
module "observability" {
  source      = "../../modules/observability"
  name_prefix = local.name_prefix

  monthly_budget_usd  = var.monthly_budget_usd
  budget_alert_emails = var.budget_alert_emails
  ask_lambda_name     = module.ask_api.lambda_name
}

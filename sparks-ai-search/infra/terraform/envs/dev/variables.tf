###############################################################################
# variables.tf — inputs for the Dev environment.
# Set real values in dev.tfvars (copy from dev.tfvars.example).
# Each variable has a comment explaining what it is and why it matters.
###############################################################################

variable "env" {
  description = "Environment name (dev, prod). Used in resource names + tags."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region. MUST match the SPARKS data residency region."
  type        = string
}

variable "cost_center" {
  description = "Cost center tag so AWS Budgets/cost reports attribute spend correctly."
  type        = string
  default     = "SPARKS-AI"
}

# ---- Networking (keep the data plane private) -------------------------------
variable "vpc_id" {
  description = "VPC the AI stack runs in (same VPC as SPARKS data access)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for Lambdas + VPC endpoints (no public access)."
  type        = list(string)
}

# ---- Data source (READ-ONLY) ------------------------------------------------
variable "sparks_db_secret_arn" {
  description = "Secrets Manager ARN with READ-ONLY credentials to the SPARKS DB (for the extractor + getX tools). Must map to a read-only role/views."
  type        = string
}

variable "outbox_read_sql" {
  description = "Read-only SELECT the extractor runs against sparks.open_search_json. Overridable so DBAs can point at a read-only view."
  type        = string
  default     = "SELECT osj_id, osj_table_index_name, osj_json_data, osj_update_dt FROM sparks.open_search_json"
}

# ---- Bedrock models (must be enabled in the account) ------------------------
variable "bedrock_embedding_model_id" {
  description = "Embedding model id, e.g. amazon.titan-embed-text-v2:0"
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "bedrock_answer_model_id" {
  description = "LLM for grounded answers, e.g. anthropic.claude-3-5-sonnet-20240620-v1:0"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "bedrock_cheap_model_id" {
  description = "Cheaper model for intent/classify/followups, e.g. anthropic.claude-3-haiku-20240307-v1:0"
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

# ---- Behavior toggles -------------------------------------------------------
variable "enable_agent" {
  description = "false = Option 1 (RAG) only. true = also deploy Option 2 (Agentic) tools + Bedrock Agent."
  type        = bool
  default     = false
}

variable "refresh_schedule" {
  description = "EventBridge schedule for the search content refresh (cron/rate). Decoupled from the existing 5-min pipeline."
  type        = string
  default     = "rate(15 minutes)"
}

variable "top_k" {
  description = "Default number of chunks retrieved per query (cost + relevance lever)."
  type        = number
  default     = 8
}

variable "agent_max_tool_calls" {
  description = "Loop cap for Option 2 so agent token cost is bounded."
  type        = number
  default     = 6
}

# ---- Cost guardrail ---------------------------------------------------------
variable "monthly_budget_usd" {
  description = "Hard monthly cost cap for the Dev pilot (AWS Budgets alarms at 50/80/100%)."
  type        = number
  default     = 200
}

variable "budget_alert_emails" {
  description = "Emails to notify on budget thresholds."
  type        = list(string)
  default     = []
}

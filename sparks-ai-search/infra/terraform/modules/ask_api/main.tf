###############################################################################
# module: ask_api
# Purpose: the user-facing entry point. API Gateway (PRIVATE) + the "Ask" Lambda
#          that implements /ask, /ask/stream, /health.
#
# Flow inside the Ask Lambda:
#   mode = "rag"   -> Bedrock KB Retrieve (top_k) -> Claude generate -> grounded answer + citations(uniqueId)
#   mode = "agent" -> invoke Bedrock Agent (var.agent_id)           -> grounded answer + citations(uniqueId)
#   always: emit usage (tokens), latency, request_id to CloudWatch; stream via SSE on /ask/stream
#
# Resources this module owns (fill in when approved):
#   - aws_lambda_function "ask"      (VPC, env: KB id, model ids, top_k, agent_id)
#   - aws_iam_role/policy            : invoke ONLY the specific Bedrock model(s) + KB; logs
#   - aws_apigatewayv2_api (HTTP)    : private; routes /ask, /ask/stream, /health
#   - aws_apigatewayv2_authorizer    : IAM / Okta JWT (ties to SB-6561 Okta story)
#   - usage plan / throttling        : per-user + global rate limits
#   - aws_wafv2_web_acl (optional)   : edge protection
###############################################################################

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "knowledge_base_id" { type = string }
variable "bedrock_answer_model_id" { type = string }
variable "bedrock_cheap_model_id" { type = string }
variable "top_k" { type = number }
variable "enable_agent" { type = bool }
variable "agent_id" {
  type    = string
  default = null
}

output "invoke_url" {
  description = "Base URL for the /ask endpoint."
  value       = "https://${var.name_prefix}-ask.execute-api.local" # placeholder
}

output "lambda_name" {
  description = "Ask Lambda name (used by observability alarms)."
  value       = "${var.name_prefix}-ask" # placeholder
}

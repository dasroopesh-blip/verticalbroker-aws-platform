###############################################################################
# module: agent  (Option 2 — only deployed when enable_agent = true)
# Purpose: a Bedrock Agent that plans multi-step answers and calls an APPROVED,
#          read-only tool set. The existing OpenSearch is reused AS A TOOL.
#
# Tools = Bedrock Action Groups backed by Lambdas (all read-only, no raw SQL):
#   - semanticSearch(query, filters, top_k)      -> Bedrock KB (knowledge_base_id)
#   - openSearchSearch(query, filters)           -> EXISTING sparks-stage domain (unchanged)
#   - getInvestigation/getVehicle/getEquipment(uniqueId) -> RDS READ-ONLY VIEWS
#
# Resources this module owns (fill in when approved):
#   - aws_bedrockagent_agent               (instruction, answer_model_id, guardrail)
#   - aws_bedrockagent_agent_action_group  (x3; each with an OpenAPI schema)
#   - aws_lambda_function x{tool-semantic, tool-keyword, tool-get}
#   - aws_iam_role/policy per tool         : LEAST-PRIVILEGE to its one data source
#   - aws_bedrock_guardrail                : denied topics + PII + grounding
#   - loop cap = var.max_tool_calls        : bounds agent token cost
###############################################################################

variable "name_prefix" { type = string }
variable "knowledge_base_id" { type = string }
variable "sparks_db_secret_arn" { type = string } # read-only views only
variable "existing_opensearch" { type = string }  # "sparks-stage" — reused, not modified
variable "max_tool_calls" { type = number }
variable "answer_model_id" { type = string }

output "agent_id" {
  description = "Bedrock Agent id (passed to the Ask Lambda when mode=agent)."
  value       = "${var.name_prefix}-agent" # placeholder
}

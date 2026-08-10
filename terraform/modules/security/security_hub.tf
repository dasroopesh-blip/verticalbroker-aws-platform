# Per-Account Security Hub Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Purpose: Per-account Security Hub with AWS Foundational Security Best Practices
#          (FSBP) and CIS Benchmark standards enabled, plus automated findings
#          response via EventBridge.
#          Complements Organization-level Security Hub in global/baseline_security.tf.
#
# Requirements: 14.6 (Security event detection within 60 seconds)
# Requirements: 14.8 (SOC 2 Type II audit evidence generation)
# Requirements: 20.5 (Baseline security controls per account)

# ---------------------------------------------------------
# SECURITY HUB - Per-Account Enablement (Requirement 20.5)
# ---------------------------------------------------------

resource "aws_securityhub_account" "environment" {
  count = var.enable_security_hub ? 1 : 0

  enable_default_standards = false

  auto_enable_controls = true
}

# ---------------------------------------------------------
# SECURITY STANDARDS - FSBP (Requirement 14.8, 20.5)
# AWS Foundational Security Best Practices
# ---------------------------------------------------------

resource "aws_securityhub_standards_subscription" "fsbp" {
  count = var.enable_security_hub ? 1 : 0

  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.environment]
}

# ---------------------------------------------------------
# SECURITY STANDARDS - CIS AWS Foundations Benchmark (Requirement 14.8)
# CIS v1.4.0 covers IAM, logging, monitoring, networking controls
# ---------------------------------------------------------

resource "aws_securityhub_standards_subscription" "cis" {
  count = var.enable_security_hub ? 1 : 0

  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [aws_securityhub_account.environment]
}

# ---------------------------------------------------------
# AUTOMATED FINDINGS RESPONSE - CRITICAL/HIGH → SNS (Requirement 14.6)
# Routes Security Hub findings to security team within 60s
# ---------------------------------------------------------

resource "aws_cloudwatch_event_rule" "securityhub_critical_findings" {
  count = var.enable_security_hub ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-securityhub-critical"
  description = "Routes Security Hub CRITICAL/HIGH findings to security team (Req 14.6: <60s)"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = {
          Label = ["CRITICAL", "HIGH"]
        }
        Workflow = {
          Status = ["NEW"]
        }
      }
    }
  })

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-securityhub-findings-rule"
    Service = "security-hub"
  })
}

resource "aws_cloudwatch_event_target" "securityhub_to_sns" {
  count = var.enable_security_hub && var.security_notification_topic_arn != "" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.securityhub_critical_findings[0].name
  target_id = "securityhub-to-security-sns"
  arn       = var.security_notification_topic_arn
}

# ---------------------------------------------------------
# AUTOMATED FINDINGS RESPONSE - FAILED COMPLIANCE → EventBridge
# Emit compliance.alert for platform-wide handling
# ---------------------------------------------------------

resource "aws_cloudwatch_event_rule" "securityhub_compliance_failed" {
  count = var.enable_security_hub ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-securityhub-compliance-failed"
  description = "Routes Security Hub FAILED compliance findings for automated remediation"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Compliance = {
          Status = ["FAILED"]
        }
        Severity = {
          Label = ["CRITICAL", "HIGH", "MEDIUM"]
        }
      }
    }
  })

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-securityhub-compliance-rule"
    Service = "security-hub"
  })
}

# ---------------------------------------------------------
# SECURITY HUB ACTION TARGET - Custom Actions (Requirement 14.8)
# Allows SOC 2 audit evidence collection from findings
# ---------------------------------------------------------

resource "aws_securityhub_action_target" "send_to_audit" {
  count = var.enable_security_hub ? 1 : 0

  name        = "SendToAudit"
  identifier  = "SendToAudit"
  description = "Send findings to SOC 2 audit evidence collection (Req 14.8)"

  depends_on = [aws_securityhub_account.environment]
}

resource "aws_securityhub_action_target" "remediate" {
  count = var.enable_security_hub ? 1 : 0

  name        = "AutoRemediate"
  identifier  = "AutoRemediate"
  description = "Trigger automated remediation for non-compliant resources"

  depends_on = [aws_securityhub_account.environment]
}

# ---------------------------------------------------------
# SECURITY HUB INSIGHT - Custom Findings Aggregation
# Track compliance posture for FINRA-regulated resources
# ---------------------------------------------------------

resource "aws_securityhub_insight" "encryption_compliance" {
  count = var.enable_security_hub ? 1 : 0

  name = "${var.platform_name}-${var.environment}-encryption-compliance"

  filters {
    type {
      comparison = "PREFIX"
      value      = "Software and Configuration Checks/Industry and Regulatory Standards"
    }
    compliance_status {
      comparison = "EQUALS"
      value      = "FAILED"
    }
    resource_tags {
      comparison = "EQUALS"
      key        = "Compliance"
      value      = "FINRA-4511"
    }
  }

  group_by_attribute = "ResourceType"

  depends_on = [aws_securityhub_account.environment]
}

resource "aws_securityhub_insight" "public_access_findings" {
  count = var.enable_security_hub ? 1 : 0

  name = "${var.platform_name}-${var.environment}-public-access-findings"

  filters {
    type {
      comparison = "PREFIX"
      value      = "Effects/Data Exposure"
    }
    resource_tags {
      comparison = "EQUALS"
      key        = "Environment"
      value      = var.environment
    }
  }

  group_by_attribute = "ResourceId"

  depends_on = [aws_securityhub_account.environment]
}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "security_hub_account_id" {
  description = "Security Hub account registration ID"
  value       = var.enable_security_hub ? aws_securityhub_account.environment[0].id : null
}

output "security_hub_fsbp_subscription_arn" {
  description = "FSBP standards subscription ARN"
  value       = var.enable_security_hub ? aws_securityhub_standards_subscription.fsbp[0].id : null
}

output "security_hub_cis_subscription_arn" {
  description = "CIS Benchmark standards subscription ARN"
  value       = var.enable_security_hub ? aws_securityhub_standards_subscription.cis[0].id : null
}

output "security_hub_findings_event_rule_arn" {
  description = "EventBridge rule ARN for Security Hub critical findings"
  value       = var.enable_security_hub ? aws_cloudwatch_event_rule.securityhub_critical_findings[0].arn : null
}

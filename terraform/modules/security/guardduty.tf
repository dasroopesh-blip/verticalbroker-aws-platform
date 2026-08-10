# Per-Account GuardDuty Detector Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Purpose: Per-environment GuardDuty detector with S3 data source,
#          threat intelligence set, and SNS notification for findings.
#          Complements the Organization-level GuardDuty in global/baseline_security.tf.
#
# Requirements: 14.6 (Security event detection within 60 seconds)
# Requirements: 20.5 (Baseline security controls per account)

# ---------------------------------------------------------
# GUARDDUTY DETECTOR - Per-Account (Requirement 14.6, 20.5)
# Enables threat detection in this account/environment with
# S3 data source monitoring for data exfiltration patterns.
# ---------------------------------------------------------

resource "aws_guardduty_detector" "environment" {
  count = var.enable_guardduty ? 1 : 0

  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = false
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-guardduty"
    Service = "guardduty"
  })
}

# ---------------------------------------------------------
# THREAT INTELLIGENCE SET (Requirement 14.6)
# Custom threat intel feed for financial services IOCs
# ---------------------------------------------------------

resource "aws_guardduty_threatintelset" "custom_feed" {
  count = var.enable_guardduty && var.guardduty_threat_intel_set_url != "" ? 1 : 0

  activate    = true
  detector_id = aws_guardduty_detector.environment[0].id
  format      = "STIX"
  location    = var.guardduty_threat_intel_set_url
  name        = "${var.platform_name}-${var.environment}-threat-intel"

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-threat-intel-set"
    Service = "guardduty"
  })
}

# ---------------------------------------------------------
# GUARDDUTY FINDINGS → SNS NOTIFICATION (Requirement 14.6)
# Routes HIGH/CRITICAL findings to security team within 60s
# ---------------------------------------------------------

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  count = var.enable_guardduty ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-guardduty-findings"
  description = "Routes GuardDuty HIGH/CRITICAL findings to SNS for <60s alerting (Req 14.6)"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-guardduty-event-rule"
    Service = "guardduty"
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  count = var.enable_guardduty && var.security_notification_topic_arn != "" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "guardduty-to-security-sns"
  arn       = var.security_notification_topic_arn
}

# ---------------------------------------------------------
# GUARDDUTY FINDINGS → EVENTBRIDGE CUSTOM BUS
# Emit compliance.alert events for platform consumption
# ---------------------------------------------------------

resource "aws_cloudwatch_event_rule" "guardduty_compliance_alert" {
  count = var.enable_guardduty ? 1 : 0

  name        = "${var.platform_name}-${var.environment}-guardduty-compliance"
  description = "Emit compliance.alert for unauthorized access, privilege escalation, data exfiltration"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      type = [
        { prefix = "UnauthorizedAccess:" },
        { prefix = "PrivilegeEscalation:" },
        { prefix = "Exfiltration:" },
        { prefix = "CredentialAccess:" }
      ]
    }
  })

  tags = merge(var.tags, {
    Name    = "${var.platform_name}-${var.environment}-guardduty-compliance-rule"
    Service = "guardduty"
  })
}

# ---------------------------------------------------------
# GUARDDUTY PUBLISHING DESTINATION
# Export findings to S3 in the security account for long-term retention
# ---------------------------------------------------------

resource "aws_guardduty_publishing_destination" "s3" {
  count = var.enable_guardduty && var.cloudtrail_s3_bucket_name != "" ? 1 : 0

  detector_id     = aws_guardduty_detector.environment[0].id
  destination_arn = "arn:aws:s3:::${var.cloudtrail_s3_bucket_name}/guardduty/${var.environment}"
  kms_key_arn     = var.cloudtrail_kms_key_arn != "" ? var.cloudtrail_kms_key_arn : null

  depends_on = [aws_guardduty_detector.environment]
}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for this environment"
  value       = var.enable_guardduty ? aws_guardduty_detector.environment[0].id : null
}

output "guardduty_detector_arn" {
  description = "GuardDuty detector ARN for this environment"
  value       = var.enable_guardduty ? aws_guardduty_detector.environment[0].arn : null
}

output "guardduty_findings_event_rule_arn" {
  description = "EventBridge rule ARN for GuardDuty findings"
  value       = var.enable_guardduty ? aws_cloudwatch_event_rule.guardduty_findings[0].arn : null
}

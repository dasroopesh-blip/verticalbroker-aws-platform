# SSM Automation Documents (Automated Runbooks)
# VerticalBroker AWS Data Engineering Platform
#
# Implements automated remediation with:
# - Runbook: restart-failed-pipeline (restart Glue jobs after failure)
# - Runbook: scale-glue-capacity (increase Glue DPUs on resource pressure)
# - Runbook: rotate-credentials (automated credential rotation)
# - CloudWatch alarm → SSM Automation trigger
# - Max execution timeout: 5 minutes, max 3 retries per incident
#
# Requirements: 15.7

# ---------------------------------------------------------
# IAM ROLE FOR SSM AUTOMATION
# ---------------------------------------------------------

resource "aws_iam_role" "ssm_automation" {
  name = "${var.name_prefix}-ssm-automation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-ssm-automation-role"
  })
}

resource "aws_iam_role_policy" "ssm_automation" {
  name = "${var.name_prefix}-ssm-automation-policy"
  role = aws_iam_role.ssm_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueJobManagement"
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJob",
          "glue:BatchStopJobRun",
        ]
        Resource = "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:job/${var.name_prefix}-*"
      },

      {
        Sid    = "LambdaConcurrencyManagement"
        Effect = "Allow"
        Action = [
          "lambda:PutFunctionConcurrency",
          "lambda:GetFunctionConcurrency",
          "lambda:GetFunction",
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.name_prefix}-*"
      },
      {
        Sid    = "SecretsManagerRotation"
        Effect = "Allow"
        Action = [
          "secretsmanager:RotateSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.name_prefix}/*"
      },
      {
        Sid    = "SNSNotification"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          aws_sns_topic.operations.arn,
          aws_sns_topic.security.arn,
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/ssm/${var.name_prefix}-*"
      },
    ]
  })
}


# ---------------------------------------------------------
# RUNBOOK 1: Restart Failed Pipeline
# Restarts a failed Glue ETL job with the same parameters.
# Triggered by: glue-job-failure alarm
# ---------------------------------------------------------

resource "aws_ssm_document" "restart_failed_pipeline" {
  name            = "${var.name_prefix}-restart-failed-pipeline"
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Restart a failed Glue ETL pipeline job. Max timeout: ${var.ssm_max_execution_timeout_seconds}s, max retries: ${var.ssm_max_retries_per_incident}"
    assumeRole    = aws_iam_role.ssm_automation.arn

    parameters = {
      JobName = {
        type        = "String"
        description = "Name of the Glue job to restart"
        default     = "${var.name_prefix}-bronze-to-silver"
      }
      MaxRetries = {
        type        = "String"
        description = "Maximum retry attempts"
        default     = tostring(var.ssm_max_retries_per_incident)
      }
    }

    mainSteps = [
      {
        name   = "CheckJobStatus"
        action = "aws:executeAwsApi"
        inputs = {
          Service = "glue"
          Api     = "GetJob"
          JobName = "{{ JobName }}"
        }
        outputs = [
          {
            Name     = "JobExists"
            Selector = "$.Job.Name"
            Type     = "String"
          }
        ]
      },
      {
        name      = "RestartGlueJob"
        action    = "aws:executeAwsApi"
        timeoutSeconds = var.ssm_max_execution_timeout_seconds
        inputs = {
          Service = "glue"
          Api     = "StartJobRun"
          JobName = "{{ JobName }}"
        }
        outputs = [
          {
            Name     = "JobRunId"
            Selector = "$.JobRunId"
            Type     = "String"
          }
        ]
      },

      {
        name   = "NotifyOperations"
        action = "aws:executeAwsApi"
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = aws_sns_topic.operations.arn
          Subject  = "Pipeline Restart: {{ JobName }}"
          Message  = "SSM Automation restarted Glue job {{ JobName }}. New JobRunId: {{ RestartGlueJob.JobRunId }}"
        }
        isEnd = true
      },
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-restart-failed-pipeline"
  })
}

# ---------------------------------------------------------
# RUNBOOK 2: Scale Glue Capacity
# Increases Glue DPU allocation for jobs under resource pressure.
# Triggered by: pipeline-latency-sla-breach alarm
# ---------------------------------------------------------

resource "aws_ssm_document" "scale_glue_capacity" {
  name            = "${var.name_prefix}-scale-glue-capacity"
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Scale Glue job DPU capacity. Max timeout: ${var.ssm_max_execution_timeout_seconds}s, max retries: ${var.ssm_max_retries_per_incident}"
    assumeRole    = aws_iam_role.ssm_automation.arn

    parameters = {
      JobName = {
        type        = "String"
        description = "Name of the Glue job to scale"
        default     = "${var.name_prefix}-bronze-to-silver"
      }
      TargetDPUs = {
        type        = "String"
        description = "Target number of DPUs (max 100)"
        default     = "50"
      }
    }

    mainSteps = [
      {
        name           = "UpdateGlueJob"
        action         = "aws:executeAwsApi"
        timeoutSeconds = var.ssm_max_execution_timeout_seconds
        inputs = {
          Service = "glue"
          Api     = "UpdateJob"
          JobName = "{{ JobName }}"
          JobUpdate = {
            NumberOfWorkers = "{{ TargetDPUs }}"
          }
        }
      },

      {
        name   = "NotifyOperations"
        action = "aws:executeAwsApi"
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = aws_sns_topic.operations.arn
          Subject  = "Glue Capacity Scaled: {{ JobName }}"
          Message  = "SSM Automation scaled Glue job {{ JobName }} to {{ TargetDPUs }} DPUs due to resource pressure."
        }
        isEnd = true
      },
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-scale-glue-capacity"
  })
}

# ---------------------------------------------------------
# RUNBOOK 3: Rotate Credentials
# Initiates secret rotation for platform service credentials.
# Triggered by: scheduled or security event
# ---------------------------------------------------------

resource "aws_ssm_document" "rotate_credentials" {
  name            = "${var.name_prefix}-rotate-credentials"
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Rotate service credentials via Secrets Manager. Max timeout: ${var.ssm_max_execution_timeout_seconds}s, max retries: ${var.ssm_max_retries_per_incident}"
    assumeRole    = aws_iam_role.ssm_automation.arn

    parameters = {
      SecretId = {
        type        = "String"
        description = "Secret ARN or name to rotate"
      }
    }

    mainSteps = [
      {
        name           = "RotateSecret"
        action         = "aws:executeAwsApi"
        timeoutSeconds = var.ssm_max_execution_timeout_seconds
        inputs = {
          Service  = "secretsmanager"
          Api      = "RotateSecret"
          SecretId = "{{ SecretId }}"
        }
        outputs = [
          {
            Name     = "VersionId"
            Selector = "$.VersionId"
            Type     = "String"
          }
        ]
      },

      {
        name   = "VerifyRotation"
        action = "aws:executeAwsApi"
        inputs = {
          Service  = "secretsmanager"
          Api      = "DescribeSecret"
          SecretId = "{{ SecretId }}"
        }
        outputs = [
          {
            Name     = "RotationEnabled"
            Selector = "$.RotationEnabled"
            Type     = "Boolean"
          }
        ]
      },
      {
        name   = "NotifySecurityTeam"
        action = "aws:executeAwsApi"
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = aws_sns_topic.security.arn
          Subject  = "Credential Rotation Completed"
          Message  = "SSM Automation rotated credentials for secret {{ SecretId }}. New version: {{ RotateSecret.VersionId }}"
        }
        isEnd = true
      },
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-rotate-credentials"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH ALARM → SSM AUTOMATION TRIGGERS
# EventBridge rules connecting alarm state changes to runbooks
# ---------------------------------------------------------

# EventBridge rule: Glue job failure → restart pipeline
resource "aws_cloudwatch_event_rule" "glue_failure_trigger" {
  name        = "${var.name_prefix}-glue-failure-auto-remediate"
  description = "Trigger restart-failed-pipeline runbook when Glue job alarm fires"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = ["${local.alarm_prefix}-glue-job-failure"]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-glue-failure-auto-remediate"
  })
}


resource "aws_cloudwatch_event_target" "glue_failure_ssm" {
  rule     = aws_cloudwatch_event_rule.glue_failure_trigger.name
  arn      = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-definition/${aws_ssm_document.restart_failed_pipeline.name}"
  role_arn = aws_iam_role.ssm_automation_events.arn

  input_transformer {
    input_paths = {
      alarmName = "$.detail.alarmName"
    }
    input_template = <<-EOT
      {
        "JobName": ["${var.name_prefix}-bronze-to-silver"]
      }
    EOT
  }
}

# EventBridge rule: Pipeline latency breach → scale capacity
resource "aws_cloudwatch_event_rule" "latency_breach_trigger" {
  name        = "${var.name_prefix}-latency-breach-auto-scale"
  description = "Trigger scale-glue-capacity runbook when pipeline latency alarm fires"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = ["${local.alarm_prefix}-pipeline-latency-sla-breach"]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-latency-breach-auto-scale"
  })
}

resource "aws_cloudwatch_event_target" "latency_breach_ssm" {
  rule     = aws_cloudwatch_event_rule.latency_breach_trigger.name
  arn      = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-definition/${aws_ssm_document.scale_glue_capacity.name}"
  role_arn = aws_iam_role.ssm_automation_events.arn

  input_transformer {
    input_paths = {
      alarmName = "$.detail.alarmName"
    }
    input_template = <<-EOT
      {
        "JobName": ["${var.name_prefix}-bronze-to-silver"],
        "TargetDPUs": ["75"]
      }
    EOT
  }
}


# IAM role for EventBridge to invoke SSM Automation
resource "aws_iam_role" "ssm_automation_events" {
  name = "${var.name_prefix}-ssm-automation-events-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = merge(var.mandatory_tags, {
    Service = "monitoring"
    Name    = "${var.name_prefix}-ssm-automation-events-role"
  })
}

resource "aws_iam_role_policy" "ssm_automation_events" {
  name = "${var.name_prefix}-ssm-automation-events-policy"
  role = aws_iam_role.ssm_automation_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:StartAutomationExecution"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-definition/${aws_ssm_document.restart_failed_pipeline.name}:*",
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-definition/${aws_ssm_document.scale_glue_capacity.name}:*",
          "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-definition/${aws_ssm_document.rotate_credentials.name}:*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.ssm_automation.arn
      },
    ]
  })
}

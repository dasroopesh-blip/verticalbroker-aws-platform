# DMS CDC Pipeline - Change Data Capture Replication Infrastructure
# VerticalBroker AWS Data Engineering Platform
#
# Implements AWS Database Migration Service (DMS) for Change Data Capture
# from source transactional databases (RDS/Aurora PostgreSQL) to the
# Bronze S3 data lake layer in Parquet format.
#
# Design Parameters:
#   - Replication instance: dms.r6i.2xlarge (multi-AZ)
#   - Source: RDS/Aurora PostgreSQL (trading schema)
#   - Target: S3 Bronze layer (Parquet output format)
#   - Migration type: full-load-and-cdc (initial bulk + ongoing replication)
#   - Replication lag alert threshold: 60 seconds
#   - Batch apply: enabled with batch_size 1000 for throughput
#   - Table mappings: all tables in the 'trading' schema
#   - LOB handling: limited LOB mode (64KB max) for performance
#   - Parallel load: enabled for full-load phase
#   - Target format: Parquet with date-based partitioning
#
# Requirements: 5.1, 5.2, 5.3, 5.6

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  dms_replication_instance_id = "${var.name_prefix}-cdc-replication"
  dms_source_endpoint_id      = "${var.name_prefix}-source-postgresql"
  dms_target_endpoint_id      = "${var.name_prefix}-target-s3-bronze"
  dms_replication_task_id     = "${var.name_prefix}-cdc-trading"
}

# ---------------------------------------------------------
# DMS REPLICATION SUBNET GROUP
# Deploy DMS instance within private data subnets across AZs
# Requirement 20.3: All resources in private subnets
# ---------------------------------------------------------

resource "aws_dms_replication_subnet_group" "cdc" {
  replication_subnet_group_id          = "${var.name_prefix}-cdc-subnet-group"
  replication_subnet_group_description = "DMS CDC replication subnet group for VerticalBroker trading data capture"

  subnet_ids = var.dms_subnet_ids

  tags = merge(var.mandatory_tags, var.tags, {
    Name      = "${var.name_prefix}-cdc-subnet-group"
    Service   = "dms"
    Component = "cdc-pipeline"
    Purpose   = "dms-replication-networking"
  })
}

# ---------------------------------------------------------
# DMS REPLICATION INSTANCE
# Requirement 5.1: Replicate changes using AWS DMS with CDC enabled
# Multi-AZ for high availability, dms.r6i.2xlarge for throughput
# ---------------------------------------------------------

resource "aws_dms_replication_instance" "cdc" {
  replication_instance_id    = local.dms_replication_instance_id
  replication_instance_class = var.dms_instance_class
  allocated_storage          = var.dms_allocated_storage_gb
  engine_version             = var.dms_engine_version

  # Multi-AZ deployment for high availability
  # Ensures CDC pipeline continuity during AZ failures
  multi_az = var.dms_multi_az

  # Network configuration: private subnets, no public access
  replication_subnet_group_id = aws_dms_replication_subnet_group.cdc.id
  publicly_accessible         = false
  vpc_security_group_ids      = var.dms_security_group_ids

  # Encryption at rest using KMS CMK (Confidential classification)
  # Requirement 14.1: All data encrypted with classification-appropriate keys
  kms_key_arn = var.kms_key_arn

  # Auto minor version upgrade for security patches
  auto_minor_version_upgrade = true

  # Apply changes during maintenance window to avoid disruption
  apply_immediately = var.environment != "production"

  # Preferred maintenance window (Sunday 03:00-04:00 UTC)
  preferred_maintenance_window = var.dms_maintenance_window

  tags = merge(var.mandatory_tags, var.tags, {
    Name               = local.dms_replication_instance_id
    Service            = "dms"
    Component          = "cdc-pipeline"
    DataClassification = "Confidential"
    Purpose            = "cdc-replication-instance"
    InstanceClass      = var.dms_instance_class
    MultiAZ            = tostring(var.dms_multi_az)
  })
}

# ---------------------------------------------------------
# DMS SOURCE ENDPOINT - RDS/Aurora PostgreSQL
# Connects to the source transactional database for CDC capture
# Requirement 5.1: Replicate changes from source relational databases
# ---------------------------------------------------------

resource "aws_dms_endpoint" "source_postgresql" {
  endpoint_id   = local.dms_source_endpoint_id
  endpoint_type = "source"
  engine_name   = "aurora-postgresql"

  # Connection settings for source database
  server_name   = var.source_db_hostname
  port          = var.source_db_port
  database_name = var.source_db_name
  username      = var.source_db_username
  password      = var.source_db_password

  # SSL mode for in-transit encryption
  # Requirement 14.2: TLS 1.3 minimum for all communications
  ssl_mode = "require"

  # PostgreSQL-specific settings for CDC
  # Uses logical replication (pglogical/test_decoding) for change capture
  extra_connection_attributes = join(";", [
    "PluginName=pglogical",
    "heartbeatEnable=true",
    "heartbeatFrequency=5",
    "captureDDLs=true",
    "ddlArtifactsSchema=verticalbroker_cdc"
  ])

  # KMS encryption for endpoint connection credentials
  kms_key_arn = var.kms_key_arn

  tags = merge(var.mandatory_tags, var.tags, {
    Name               = local.dms_source_endpoint_id
    Service            = "dms"
    Component          = "cdc-pipeline"
    EndpointType       = "source"
    Engine             = "aurora-postgresql"
    DataClassification = "Confidential"
    Purpose            = "cdc-source-database"
  })
}

# ---------------------------------------------------------
# DMS TARGET ENDPOINT - S3 Bronze Layer (Parquet Output)
# Writes CDC records to the Bronze layer in Parquet format
# with date-based partitioning for efficient downstream processing
# Requirement 5.1: Replicate changes to the Bronze_Layer
# ---------------------------------------------------------

resource "aws_dms_endpoint" "target_s3_bronze" {
  endpoint_id   = local.dms_target_endpoint_id
  endpoint_type = "target"
  engine_name   = "s3"

  s3_settings {
    # Target S3 bucket for CDC output (Bronze layer)
    bucket_name        = var.bronze_bucket_name
    bucket_folder      = "cdc/trading"
    service_access_role_arn = var.dms_s3_target_role_arn

    # Output format: Parquet for optimal analytics performance
    # Requirement 3.4: Parquet format for downstream ETL compatibility
    data_format         = "parquet"
    parquet_version     = "parquet-2-0"
    encoding_type       = "plain-dictionary"
    compression_type    = "GZIP"

    # Date-based partitioning for Hive-style compatibility
    # Format: cdc/trading/{schema}/{table}/year=YYYY/month=MM/day=DD/
    # Requirement 2.1: Hive-style partitioning
    date_partition_enabled   = true
    date_partition_sequence  = "YYYYMMDD"
    date_partition_delimiter = "SLASH"

    # Include CDC operation metadata in output
    # Requirement 5.3: Preserve operation type, before-image, after-image
    include_op_for_full_load    = true
    cdc_inserts_and_updates     = false
    add_column_name             = true
    timestamp_column_name       = "cdc_timestamp"
    cdc_max_batch_interval      = 60
    cdc_min_file_size           = 32000

    # Encryption using KMS CMK
    encryption_mode                  = "SSE_KMS"
    server_side_encryption_kms_key_id = var.kms_key_arn

    # External table definition for Glue Data Catalog integration
    external_table_definition = ""
  }

  # KMS encryption for endpoint configuration
  kms_key_arn = var.kms_key_arn

  tags = merge(var.mandatory_tags, var.tags, {
    Name               = local.dms_target_endpoint_id
    Service            = "dms"
    Component          = "cdc-pipeline"
    EndpointType       = "target"
    Engine             = "s3"
    OutputFormat        = "parquet"
    DataClassification = "Confidential"
    Purpose            = "cdc-target-s3-bronze"
  })
}

# ---------------------------------------------------------
# DMS REPLICATION TASK - Full Load + CDC
# Requirement 5.1: Replicate changes using DMS with CDC enabled
# Requirement 5.6: Full-load resync without impacting ongoing CDC
# Migration type: full-load-and-cdc for initial bulk + ongoing streaming
# ---------------------------------------------------------

resource "aws_dms_replication_task" "cdc_trading" {
  replication_task_id = local.dms_replication_task_id

  # Migration type: full-load-and-cdc
  # - Performs initial full table load of all existing data
  # - Then automatically transitions to ongoing CDC streaming
  # Requirement 5.6: Supports full-load resync via separate task
  migration_type = "full-load-and-cdc"

  # Instance and endpoint associations
  replication_instance_arn = aws_dms_replication_instance.cdc.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source_postgresql.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target_s3_bronze.endpoint_arn

  # Table mappings: include all tables in the 'trading' schema
  # Requirement 5.1: Capture all trading-related tables
  table_mappings = jsonencode({
    rules = [
      {
        rule-type   = "selection"
        rule-id     = "1"
        rule-name   = "include-trading-schema"
        rule-action = "include"
        object-locator = {
          schema-name = "trading"
          table-name  = "%"
        }
      },
      {
        rule-type   = "transformation"
        rule-id     = "2"
        rule-name   = "add-schema-prefix"
        rule-action = "add-prefix"
        rule-target = "table"
        object-locator = {
          schema-name = "trading"
          table-name  = "%"
        }
        value = "trading_"
      }
    ]
  })

  # Task settings: parallel load, LOB handling, logging, batch apply
  replication_task_settings = jsonencode({
    TargetMetadata = {
      TargetSchema          = ""
      SupportLobs           = true
      FullLobMode           = false
      LobChunkSize          = 64
      LimitedSizeLobMode    = true
      LobMaxSize            = 64
      InlineLobMaxSize      = 0
      LoadMaxFileSize        = 0
      ParallelLoadThreads   = var.dms_parallel_load_threads
      ParallelLoadBufferSize = var.dms_parallel_load_buffer_size
      BatchApplyEnabled     = true
    }

    FullLoadSettings = {
      TargetTablePrepMode   = "DO_NOTHING"
      CreatePkAfterFullLoad = false
      StopTaskCachedChangesApplied = false
      StopTaskCachedChangesNotApplied = false
      MaxFullLoadSubTasks   = var.dms_max_full_load_subtasks
      TransactionConsistencyTimeout = 600
      CommitRate            = 10000
    }

    Logging = {
      EnableLogging = true
      LogComponents = [
        { Id = "TRANSFORMATION", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SOURCE_UNLOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "IO", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_LOAD", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "PERFORMANCE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SOURCE_CAPTURE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SORTER", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "REST_SERVER", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "VALIDATOR_EXT", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_APPLY", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TASK_MANAGER", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TABLES_MANAGER", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "METADATA_MANAGER", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "FILE_FACTORY", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "COMMON", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "ADDONS", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "DATA_STRUCTURE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "COMMUNICATION", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "FILE_TRANSFER", Severity = "LOGGER_SEVERITY_DEFAULT" }
      ]
    }

    ControlTablesSettings = {
      historyTimeslotInMinutes              = 5
      ControlSchema                         = "dms_control"
      HistoryTimeslotInMinutes              = 5
      HistoryTableEnabled                   = true
      SuspendedTablesTableEnabled           = true
      StatusTableEnabled                    = true
      FullLoadExceptionTableEnabled         = true
    }

    StreamBufferSettings = {
      StreamBufferCount  = 3
      StreamBufferSizeInMB = 8
      CtrlStreamBufferSizeInMB = 5
    }

    ChangeProcessingDdlHandling = {
      HandleSourceTableDropped   = true
      HandleSourceTableTruncated = true
      HandleSourceTableAltered   = true
    }

    ErrorBehavior = {
      DataErrorPolicy                = "LOG_ERROR"
      DataTruncationErrorPolicy      = "LOG_ERROR"
      DataErrorEscalationPolicy      = "SUSPEND_TABLE"
      DataErrorEscalationCount       = 0
      TableErrorPolicy               = "SUSPEND_TABLE"
      TableErrorEscalationPolicy     = "STOP_TASK"
      TableErrorEscalationCount      = 5
      RecoverableErrorCount          = -1
      RecoverableErrorInterval       = 5
      RecoverableErrorThrottling     = true
      RecoverableErrorThrottlingMax  = 1800
      RecoverableErrorStopRetryAfterThrottlingMax = true
      ApplyErrorDeletePolicy         = "IGNORE_RECORD"
      ApplyErrorInsertPolicy         = "LOG_ERROR"
      ApplyErrorUpdatePolicy         = "LOG_ERROR"
      ApplyErrorEscalationPolicy     = "LOG_ERROR"
      ApplyErrorEscalationCount      = 0
      ApplyErrorFailOnTruncationDdl  = false
      FailOnNoTablesCaptured         = true
      FailOnTransactionConsistencyBreached = false
    }

    ChangeProcessingTuning = {
      BatchApplyPreserveTransaction = true
      BatchApplyTimeoutMin          = 1
      BatchApplyTimeoutMax          = 30
      BatchApplyMemoryLimit         = 500
      BatchSplitSize                = 0
      MinTransactionSize            = 1000
      CommitTimeout                 = 1
      MemoryLimitTotal              = 1024
      MemoryKeepTime                = 60
      StatementCacheSize            = 50
    }
  })

  # Start task upon creation in non-production environments
  start_replication_task = var.environment != "production"

  tags = merge(var.mandatory_tags, var.tags, {
    Name               = local.dms_replication_task_id
    Service            = "dms"
    Component          = "cdc-pipeline"
    MigrationType      = "full-load-and-cdc"
    SourceSchema       = "trading"
    DataClassification = "Confidential"
    Purpose            = "cdc-replication-task"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH ALARMS - DMS Replication Lag Monitoring
# Requirement 5.4: Alert when replication lag exceeds 60 seconds
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dms_replication_lag" {
  alarm_name          = "${local.dms_replication_task_id}-replication-lag-high"
  alarm_description   = "DMS CDC replication lag exceeds 60 seconds. Source commit to Bronze availability SLA at risk. Auto-scaling of DMS instance may be required."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CDCLatencyTarget"
  namespace           = "AWS/DMS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.dms_replication_lag_threshold_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.cdc.replication_instance_id
    ReplicationTaskIdentifier     = aws_dms_replication_task.cdc_trading.replication_task_id
  }

  # Notify operations team when lag is detected
  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, var.tags, {
    Name      = "${local.dms_replication_task_id}-replication-lag-alarm"
    Service   = "cloudwatch"
    Component = "cdc-pipeline"
    Purpose   = "dms-lag-monitoring"
    Threshold = "${var.dms_replication_lag_threshold_seconds}s"
  })
}

resource "aws_cloudwatch_metric_alarm" "dms_replication_lag_source" {
  alarm_name          = "${local.dms_replication_task_id}-source-lag-high"
  alarm_description   = "DMS CDC source latency exceeds threshold. Source database read performance may be degraded or replication slot is falling behind."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CDCLatencySource"
  namespace           = "AWS/DMS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.dms_replication_lag_threshold_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.cdc.replication_instance_id
    ReplicationTaskIdentifier     = aws_dms_replication_task.cdc_trading.replication_task_id
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, var.tags, {
    Name      = "${local.dms_replication_task_id}-source-lag-alarm"
    Service   = "cloudwatch"
    Component = "cdc-pipeline"
    Purpose   = "dms-source-lag-monitoring"
    Threshold = "${var.dms_replication_lag_threshold_seconds}s"
  })
}

resource "aws_cloudwatch_metric_alarm" "dms_full_load_throughput" {
  alarm_name          = "${local.dms_replication_task_id}-full-load-rows-low"
  alarm_description   = "DMS full load throughput is below expected rate. Full load may be stalled or experiencing source throttling."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "FullLoadThroughputRowsTarget"
  namespace           = "AWS/DMS"
  period              = 300
  statistic           = "Average"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.cdc.replication_instance_id
    ReplicationTaskIdentifier     = aws_dms_replication_task.cdc_trading.replication_task_id
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(var.mandatory_tags, var.tags, {
    Name      = "${local.dms_replication_task_id}-full-load-throughput-alarm"
    Service   = "cloudwatch"
    Component = "cdc-pipeline"
    Purpose   = "dms-full-load-monitoring"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH LOG GROUP - DMS Task Logging
# Captures DMS replication task logs for debugging and audit
# Requirement 15.6: Retain operational logs for 90 days
# ---------------------------------------------------------

resource "aws_cloudwatch_log_group" "dms_task_logs" {
  name              = "/aws/dms/tasks/${local.dms_replication_task_id}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.mandatory_tags, var.tags, {
    Name      = "${local.dms_replication_task_id}-logs"
    Service   = "cloudwatch-logs"
    Component = "cdc-pipeline"
    Purpose   = "dms-task-logging"
  })
}

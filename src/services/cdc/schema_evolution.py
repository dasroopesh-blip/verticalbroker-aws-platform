# CDC Pipeline: Schema Evolution Detection and Handling
# VerticalBroker AWS Data Engineering Platform
#
# Implements Change Data Capture pipeline components for:
#   - CDCPipelineConfig: DMS replication task configuration dataclass
#   - CDCRecord: Individual change record with before/after images
#   - SchemaChange: DDL change detection model
#   - SchemaEvolutionHandler: Detects DDL changes, updates Glue Catalog, notifies downstream
#   - ReplicationLagMonitor: Monitors lag and triggers auto-scaling of DMS instance
#
# Requirements: 5.2, 5.3, 5.4, 5.5
"""CDC Pipeline: Schema evolution detection and handling."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)



# ---------------------------------------------------------
# ENUMERATIONS
# ---------------------------------------------------------


class CDCOperationType(str, Enum):
    """DML operation types captured by CDC pipeline.

    Requirement 5.3: Capture all DML operations (INSERT, UPDATE, DELETE).
    """

    INSERT = "INSERT"
    UPDATE = "UPDATE"
    DELETE = "DELETE"


class SchemaChangeType(str, Enum):
    """DDL change types detected from DMS events.

    Requirement 5.5: Support schema evolution by detecting DDL changes.
    """

    ADD_COLUMN = "ADD_COLUMN"
    DROP_COLUMN = "DROP_COLUMN"
    ALTER_COLUMN = "ALTER_COLUMN"
    RENAME_COLUMN = "RENAME_COLUMN"
    ADD_TABLE = "ADD_TABLE"
    DROP_TABLE = "DROP_TABLE"
    RENAME_TABLE = "RENAME_TABLE"


class ReplicationInstanceSize(str, Enum):
    """DMS replication instance classes for auto-scaling.

    Requirement 5.4: Scale DMS replication instance capacity.
    """

    SMALL = "dms.r6i.large"
    MEDIUM = "dms.r6i.xlarge"
    LARGE = "dms.r6i.2xlarge"
    XLARGE = "dms.r6i.4xlarge"



# ---------------------------------------------------------
# DATA CLASSES
# ---------------------------------------------------------


@dataclass
class CDCPipelineConfig:
    """DMS replication task configuration.

    Encapsulates all settings for a CDC pipeline including source/target
    endpoints, migration type, batch settings, and table mappings.

    Requirements: 5.1, 5.2, 5.6
    """

    source_endpoint: str
    """Source RDS/Aurora PostgreSQL endpoint ARN."""

    target_endpoint: str
    """S3 Bronze target endpoint ARN."""

    replication_instance: str
    """DMS replication instance class (e.g., dms.r6i.2xlarge)."""

    migration_type: str = "full-load-and-cdc"
    """Migration type: 'full-load-and-cdc', 'cdc', or 'full-load'."""

    cdc_start_position: str = "server-time"
    """CDC start position: 'server-time' or specific LSN."""

    max_lag_seconds: int = 60
    """Maximum acceptable replication lag in seconds before alerting."""

    batch_apply_enabled: bool = True
    """Enable batch apply mode for improved throughput."""

    batch_size: int = 1000
    """Number of records per batch apply operation."""

    parallel_load_threads: int = 8
    """Number of parallel threads for full-load phase."""

    max_full_load_subtasks: int = 8
    """Maximum tables loaded in parallel during full load."""

    lob_max_size_kb: int = 64
    """Maximum LOB size in KB (limited LOB mode for performance)."""

    table_mappings: dict = field(default_factory=lambda: {
        "rules": [
            {
                "rule-type": "selection",
                "rule-id": "1",
                "rule-name": "include-trading-schema",
                "rule-action": "include",
                "object-locator": {
                    "schema-name": "trading",
                    "table-name": "%",
                },
            }
        ]
    })
    """Table mapping rules selecting which schema/tables to replicate."""



@dataclass
class CDCRecord:
    """Individual CDC record with before/after images.

    Represents a single change captured from the source database.
    Each record contains the full context needed for downstream processing
    including operation type, row state before/after the change, and
    transaction metadata.

    Requirement 5.3: Capture all DML operations preserving operation type,
    before-image, and after-image for each change.
    """

    operation: CDCOperationType
    """DML operation type: INSERT, UPDATE, or DELETE."""

    schema_name: str
    """Source database schema name (e.g., 'trading')."""

    table_name: str
    """Source table name."""

    before_image: Optional[dict[str, Any]]
    """Previous row state (present for UPDATE and DELETE operations)."""

    after_image: Optional[dict[str, Any]]
    """New row state (present for INSERT and UPDATE operations)."""

    transaction_id: str
    """Source database transaction ID for correlation."""

    commit_timestamp: datetime
    """Timestamp when the transaction was committed in the source database."""

    source_lsn: str
    """Log Sequence Number from the source database WAL."""

    metadata: dict[str, Any] = field(default_factory=dict)
    """Additional metadata: partition_key, sequence_number, etc."""

    @property
    def qualified_table_name(self) -> str:
        """Return fully qualified table name: schema.table."""
        return f"{self.schema_name}.{self.table_name}"

    @property
    def record_key(self) -> str:
        """Derive a unique key for this CDC record."""
        return f"{self.qualified_table_name}:{self.transaction_id}:{self.source_lsn}"

    def to_dict(self) -> dict[str, Any]:
        """Serialize CDC record to dictionary for event emission."""
        return {
            "operation": self.operation.value,
            "schema_name": self.schema_name,
            "table_name": self.table_name,
            "before_image": self.before_image,
            "after_image": self.after_image,
            "transaction_id": self.transaction_id,
            "commit_timestamp": self.commit_timestamp.isoformat(),
            "source_lsn": self.source_lsn,
            "metadata": self.metadata,
        }



@dataclass
class SchemaChange:
    """Detected schema change from DMS DDL event.

    Requirement 5.5: Detect DDL changes and update Glue Data Catalog.
    """

    change_type: SchemaChangeType
    """Type of DDL change detected."""

    schema_name: str
    """Source schema where the change occurred."""

    table_name: str
    """Table affected by the DDL change."""

    column_name: Optional[str] = None
    """Column affected (for column-level changes)."""

    old_data_type: Optional[str] = None
    """Previous data type (for ALTER_COLUMN)."""

    new_data_type: Optional[str] = None
    """New data type (for ADD_COLUMN, ALTER_COLUMN)."""

    is_nullable: Optional[bool] = None
    """Whether the column is nullable."""

    detected_at: datetime = field(default_factory=datetime.utcnow)
    """Timestamp when the schema change was detected."""

    source_event: dict[str, Any] = field(default_factory=dict)
    """Raw DMS event that triggered the detection."""

    def to_dict(self) -> dict[str, Any]:
        """Serialize schema change for event emission."""
        return {
            "change_type": self.change_type.value,
            "schema_name": self.schema_name,
            "table_name": self.table_name,
            "column_name": self.column_name,
            "old_data_type": self.old_data_type,
            "new_data_type": self.new_data_type,
            "is_nullable": self.is_nullable,
            "detected_at": self.detected_at.isoformat(),
        }



# ---------------------------------------------------------
# SCHEMA EVOLUTION HANDLER
# ---------------------------------------------------------

# Mapping from PostgreSQL types to Glue Data Catalog types
_PG_TO_GLUE_TYPE_MAP: dict[str, str] = {
    "integer": "int",
    "bigint": "bigint",
    "smallint": "smallint",
    "numeric": "decimal",
    "decimal": "decimal",
    "real": "float",
    "double precision": "double",
    "character varying": "string",
    "varchar": "string",
    "text": "string",
    "char": "char",
    "boolean": "boolean",
    "date": "date",
    "timestamp": "timestamp",
    "timestamp without time zone": "timestamp",
    "timestamp with time zone": "timestamp",
    "bytea": "binary",
    "json": "string",
    "jsonb": "string",
    "uuid": "string",
}


class SchemaEvolutionHandler:
    """Detect and handle DDL changes from source systems.

    Monitors DMS events for schema changes (DDL operations) and
    propagates those changes to the AWS Glue Data Catalog, ensuring
    downstream consumers (ETL jobs, Athena queries) remain compatible.

    Requirement 5.5: Support schema evolution by detecting DDL changes
    and updating the Glue Data Catalog accordingly.
    """

    def __init__(
        self,
        glue_database: str = "verticalbroker_bronze",
        event_bus_name: str = "verticalbroker-platform",
        region: Optional[str] = None,
    ):
        """Initialize SchemaEvolutionHandler.

        Args:
            glue_database: Target Glue Data Catalog database name.
            event_bus_name: EventBridge bus for schema change notifications.
            region: AWS region (defaults to AWS_REGION env var).
        """
        self._region = region or os.environ.get("AWS_REGION", "us-east-1")
        self._glue_database = glue_database
        self._event_bus_name = event_bus_name
        self._glue_client = boto3.client("glue", region_name=self._region)
        self._events_client = boto3.client("events", region_name=self._region)


    def detect_schema_change(self, event: dict[str, Any]) -> Optional[SchemaChange]:
        """Parse DMS event for DDL changes.

        Analyzes incoming DMS CloudWatch/EventBridge events to detect
        schema modifications in the source database. DMS emits events
        when DDL statements are captured (requires captureDDLs=true).

        Args:
            event: DMS event payload (from EventBridge or CloudWatch Events).

        Returns:
            SchemaChange if a DDL change is detected, None otherwise.
        """
        # DMS DDL events are structured with specific detail-type
        detail = event.get("detail", {})
        event_type = detail.get("type", "")

        # Check if this is a DDL-related DMS event
        if event_type not in (
            "SCHEMA_CHANGE",
            "TABLE_ADDED",
            "TABLE_DROPPED",
            "COLUMN_ADDED",
            "COLUMN_DROPPED",
            "COLUMN_TYPE_CHANGED",
            "COLUMN_RENAMED",
            "TABLE_RENAMED",
        ):
            return None

        schema_name = detail.get("schema_name", "")
        table_name = detail.get("table_name", "")

        change_type_mapping = {
            "COLUMN_ADDED": SchemaChangeType.ADD_COLUMN,
            "COLUMN_DROPPED": SchemaChangeType.DROP_COLUMN,
            "COLUMN_TYPE_CHANGED": SchemaChangeType.ALTER_COLUMN,
            "COLUMN_RENAMED": SchemaChangeType.RENAME_COLUMN,
            "TABLE_ADDED": SchemaChangeType.ADD_TABLE,
            "TABLE_DROPPED": SchemaChangeType.DROP_TABLE,
            "TABLE_RENAMED": SchemaChangeType.RENAME_TABLE,
            "SCHEMA_CHANGE": SchemaChangeType.ALTER_COLUMN,
        }

        change_type = change_type_mapping.get(event_type)
        if change_type is None:
            logger.warning("Unknown DDL event type: %s", event_type)
            return None

        schema_change = SchemaChange(
            change_type=change_type,
            schema_name=schema_name,
            table_name=table_name,
            column_name=detail.get("column_name"),
            old_data_type=detail.get("old_data_type"),
            new_data_type=detail.get("new_data_type"),
            is_nullable=detail.get("is_nullable"),
            source_event=event,
        )

        logger.info(
            "Detected schema change: %s on %s.%s (column: %s)",
            change_type.value,
            schema_name,
            table_name,
            detail.get("column_name", "N/A"),
        )
        return schema_change


    def update_glue_catalog(self, change: SchemaChange) -> bool:
        """Propagate schema change to AWS Glue Data Catalog.

        Updates the Glue Data Catalog table definition to reflect the
        detected DDL change from the source database. This ensures
        downstream ETL jobs and Athena queries use the correct schema.

        Requirement 5.5: Updating the Glue Data Catalog accordingly.

        Args:
            change: The detected schema change to propagate.

        Returns:
            True if the catalog was updated successfully, False otherwise.
        """
        glue_table_name = f"cdc_{change.schema_name}_{change.table_name}"

        try:
            if change.change_type == SchemaChangeType.ADD_TABLE:
                return self._create_glue_table(change, glue_table_name)
            elif change.change_type == SchemaChangeType.DROP_TABLE:
                return self._delete_glue_table(glue_table_name)
            elif change.change_type in (
                SchemaChangeType.ADD_COLUMN,
                SchemaChangeType.DROP_COLUMN,
                SchemaChangeType.ALTER_COLUMN,
                SchemaChangeType.RENAME_COLUMN,
            ):
                return self._update_glue_table_columns(change, glue_table_name)
            elif change.change_type == SchemaChangeType.RENAME_TABLE:
                # Rename requires delete old + create new
                self._delete_glue_table(glue_table_name)
                new_table_name = f"cdc_{change.schema_name}_{change.column_name}"
                return self._create_glue_table(change, new_table_name)
            else:
                logger.warning(
                    "Unhandled schema change type: %s", change.change_type.value
                )
                return False
        except ClientError as e:
            logger.error(
                "Failed to update Glue Catalog for %s: %s",
                glue_table_name,
                str(e),
            )
            return False

    def _create_glue_table(
        self, change: SchemaChange, glue_table_name: str
    ) -> bool:
        """Create a new table in the Glue Data Catalog."""
        self._glue_client.create_table(
            DatabaseName=self._glue_database,
            TableInput={
                "Name": glue_table_name,
                "Description": (
                    f"CDC table for {change.schema_name}.{change.table_name}"
                ),
                "StorageDescriptor": {
                    "Columns": [],
                    "Location": (
                        f"s3://vb-bronze/cdc/trading/"
                        f"{change.schema_name}/{change.table_name}/"
                    ),
                    "InputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
                    "OutputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
                    "SerdeInfo": {
                        "SerializationLibrary": "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
                    },
                },
                "PartitionKeys": [
                    {"Name": "year", "Type": "string"},
                    {"Name": "month", "Type": "string"},
                    {"Name": "day", "Type": "string"},
                ],
                "TableType": "EXTERNAL_TABLE",
                "Parameters": {
                    "classification": "parquet",
                    "cdc_source_schema": change.schema_name,
                    "cdc_source_table": change.table_name,
                    "created_by": "cdc-schema-evolution-handler",
                },
            },
        )
        logger.info("Created Glue table: %s", glue_table_name)
        return True


    def _delete_glue_table(self, glue_table_name: str) -> bool:
        """Delete a table from the Glue Data Catalog."""
        self._glue_client.delete_table(
            DatabaseName=self._glue_database,
            Name=glue_table_name,
        )
        logger.info("Deleted Glue table: %s", glue_table_name)
        return True

    def _update_glue_table_columns(
        self, change: SchemaChange, glue_table_name: str
    ) -> bool:
        """Update column definitions in an existing Glue table."""
        # Retrieve current table definition
        response = self._glue_client.get_table(
            DatabaseName=self._glue_database,
            Name=glue_table_name,
        )
        table_def = response["Table"]
        columns = table_def["StorageDescriptor"]["Columns"]

        if change.change_type == SchemaChangeType.ADD_COLUMN:
            glue_type = self._pg_type_to_glue(change.new_data_type or "string")
            columns.append({
                "Name": change.column_name,
                "Type": glue_type,
                "Comment": f"Added via CDC schema evolution at {change.detected_at.isoformat()}",
            })

        elif change.change_type == SchemaChangeType.DROP_COLUMN:
            columns = [
                col for col in columns if col["Name"] != change.column_name
            ]

        elif change.change_type == SchemaChangeType.ALTER_COLUMN:
            glue_type = self._pg_type_to_glue(change.new_data_type or "string")
            for col in columns:
                if col["Name"] == change.column_name:
                    col["Type"] = glue_type
                    col["Comment"] = (
                        f"Type changed from {change.old_data_type} "
                        f"to {change.new_data_type} at {change.detected_at.isoformat()}"
                    )
                    break

        elif change.change_type == SchemaChangeType.RENAME_COLUMN:
            for col in columns:
                if col["Name"] == change.old_data_type:  # old name stored here
                    col["Name"] = change.column_name
                    col["Comment"] = (
                        f"Renamed at {change.detected_at.isoformat()}"
                    )
                    break

        # Update the table with modified columns
        # Remove fields that cannot be passed to update_table
        table_input = {
            "Name": table_def["Name"],
            "StorageDescriptor": table_def["StorageDescriptor"],
            "PartitionKeys": table_def.get("PartitionKeys", []),
            "TableType": table_def.get("TableType", "EXTERNAL_TABLE"),
            "Parameters": table_def.get("Parameters", {}),
        }
        table_input["StorageDescriptor"]["Columns"] = columns
        table_input["Parameters"]["last_schema_change"] = (
            change.detected_at.isoformat()
        )
        table_input["Parameters"]["last_change_type"] = change.change_type.value

        if "Description" in table_def:
            table_input["Description"] = table_def["Description"]

        self._glue_client.update_table(
            DatabaseName=self._glue_database,
            TableInput=table_input,
        )
        logger.info(
            "Updated Glue table %s: %s on column %s",
            glue_table_name,
            change.change_type.value,
            change.column_name,
        )
        return True

    @staticmethod
    def _pg_type_to_glue(pg_type: str) -> str:
        """Convert PostgreSQL data type to Glue/Hive data type."""
        normalized = pg_type.lower().strip()
        return _PG_TO_GLUE_TYPE_MAP.get(normalized, "string")


    def notify_downstream(self, change: SchemaChange) -> bool:
        """Emit schema.evolved event for downstream consumers.

        Publishes a schema change event to EventBridge so that downstream
        services (ETL jobs, analytics pipelines) can react to schema
        modifications — for example, by refreshing their schema caches
        or triggering re-crawl operations.

        Requirement 5.5: Detecting DDL changes and updating accordingly.

        Args:
            change: The schema change to notify about.

        Returns:
            True if the event was published successfully, False otherwise.
        """
        try:
            event_detail = {
                "change_type": change.change_type.value,
                "schema_name": change.schema_name,
                "table_name": change.table_name,
                "column_name": change.column_name,
                "old_data_type": change.old_data_type,
                "new_data_type": change.new_data_type,
                "detected_at": change.detected_at.isoformat(),
                "glue_database": self._glue_database,
                "glue_table": f"cdc_{change.schema_name}_{change.table_name}",
            }

            response = self._events_client.put_events(
                Entries=[
                    {
                        "Source": "verticalbroker.cdc-pipeline",
                        "DetailType": "SchemaEvolved",
                        "Detail": json.dumps(event_detail),
                        "EventBusName": self._event_bus_name,
                    }
                ]
            )

            failed_count = response.get("FailedEntryCount", 0)
            if failed_count > 0:
                logger.error(
                    "Failed to publish schema.evolved event: %s",
                    response.get("Entries", []),
                )
                return False

            logger.info(
                "Published schema.evolved event for %s.%s (%s)",
                change.schema_name,
                change.table_name,
                change.change_type.value,
            )
            return True

        except ClientError as e:
            logger.error(
                "Error publishing schema.evolved event: %s", str(e)
            )
            return False



# ---------------------------------------------------------
# REPLICATION LAG MONITOR
# ---------------------------------------------------------

# Instance class upgrade path for auto-scaling
_INSTANCE_SCALE_UP_PATH: dict[str, str] = {
    "dms.r6i.large": "dms.r6i.xlarge",
    "dms.r6i.xlarge": "dms.r6i.2xlarge",
    "dms.r6i.2xlarge": "dms.r6i.4xlarge",
    "dms.r6i.4xlarge": "dms.r6i.8xlarge",
}

_INSTANCE_SCALE_DOWN_PATH: dict[str, str] = {
    "dms.r6i.8xlarge": "dms.r6i.4xlarge",
    "dms.r6i.4xlarge": "dms.r6i.2xlarge",
    "dms.r6i.2xlarge": "dms.r6i.xlarge",
    "dms.r6i.xlarge": "dms.r6i.large",
}


class ReplicationLagMonitor:
    """Monitor DMS replication lag and trigger auto-scaling.

    Monitors the CDC pipeline's replication latency and automatically
    scales the DMS replication instance when lag exceeds thresholds.
    Also emits warning events to EventBridge for operational awareness.

    Requirement 5.4: If replication lag exceeds 60 seconds, emit a warning
    event and scale DMS replication instance capacity.
    """

    def __init__(
        self,
        replication_instance_arn: str,
        max_lag_seconds: int = 60,
        scale_down_lag_seconds: int = 10,
        event_bus_name: str = "verticalbroker-platform",
        region: Optional[str] = None,
    ):
        """Initialize ReplicationLagMonitor.

        Args:
            replication_instance_arn: ARN of the DMS replication instance.
            max_lag_seconds: Lag threshold triggering scale-up (default: 60s).
            scale_down_lag_seconds: Lag threshold for scale-down consideration.
            event_bus_name: EventBridge bus for warning events.
            region: AWS region.
        """
        self._region = region or os.environ.get("AWS_REGION", "us-east-1")
        self._replication_instance_arn = replication_instance_arn
        self._max_lag_seconds = max_lag_seconds
        self._scale_down_lag_seconds = scale_down_lag_seconds
        self._event_bus_name = event_bus_name
        self._dms_client = boto3.client("dms", region_name=self._region)
        self._cloudwatch_client = boto3.client(
            "cloudwatch", region_name=self._region
        )
        self._events_client = boto3.client("events", region_name=self._region)


    def check_replication_lag(self) -> float:
        """Query CloudWatch for current CDC replication lag.

        Retrieves the CDCLatencyTarget metric from CloudWatch which
        represents the end-to-end latency from source commit to target
        availability.

        Returns:
            Current replication lag in seconds, or 0.0 if unavailable.
        """
        try:
            response = self._cloudwatch_client.get_metric_statistics(
                Namespace="AWS/DMS",
                MetricName="CDCLatencyTarget",
                Dimensions=[
                    {
                        "Name": "ReplicationInstanceIdentifier",
                        "Value": self._get_instance_id(),
                    }
                ],
                StartTime=datetime.utcnow().replace(
                    second=0, microsecond=0
                ).__class__(
                    *datetime.utcnow().timetuple()[:5], 0
                ),
                EndTime=datetime.utcnow(),
                Period=60,
                Statistics=["Maximum"],
            )

            datapoints = response.get("Datapoints", [])
            if not datapoints:
                return 0.0

            # Return the most recent datapoint
            latest = max(datapoints, key=lambda dp: dp["Timestamp"])
            return float(latest["Maximum"])

        except ClientError as e:
            logger.error("Failed to query replication lag metric: %s", str(e))
            return 0.0

    def evaluate_and_act(self) -> dict[str, Any]:
        """Evaluate current lag and take action if thresholds exceeded.

        Main entry point for the lag monitor. Checks current replication
        lag and either:
        - Emits a warning event + scales up (lag > max_lag_seconds)
        - Scales down (lag < scale_down_lag_seconds for sustained period)
        - Takes no action (lag within acceptable range)

        Requirement 5.4: Emit warning event and scale DMS instance capacity.

        Returns:
            Dictionary with action taken and current metrics.
        """
        current_lag = self.check_replication_lag()
        result: dict[str, Any] = {
            "current_lag_seconds": current_lag,
            "threshold_seconds": self._max_lag_seconds,
            "action_taken": "none",
            "timestamp": datetime.utcnow().isoformat(),
        }

        if current_lag > self._max_lag_seconds:
            # Lag exceeds threshold - emit warning and scale up
            logger.warning(
                "Replication lag %.1fs exceeds threshold %ds - scaling up",
                current_lag,
                self._max_lag_seconds,
            )
            self._emit_lag_warning(current_lag)
            scale_result = self._scale_up_instance()
            result["action_taken"] = "scale_up"
            result["scale_result"] = scale_result

        elif current_lag < self._scale_down_lag_seconds:
            # Lag well below threshold - consider scale down
            logger.info(
                "Replication lag %.1fs below scale-down threshold %ds",
                current_lag,
                self._scale_down_lag_seconds,
            )
            result["action_taken"] = "scale_down_candidate"

        else:
            logger.info(
                "Replication lag %.1fs within acceptable range", current_lag
            )

        return result


    def _emit_lag_warning(self, current_lag: float) -> None:
        """Emit a CDC replication lag warning event to EventBridge.

        Requirement 5.4: Emit a warning event to the Event_Bus.
        """
        try:
            self._events_client.put_events(
                Entries=[
                    {
                        "Source": "verticalbroker.cdc-pipeline",
                        "DetailType": "CDCReplicationLagWarning",
                        "Detail": json.dumps({
                            "replication_instance_arn": self._replication_instance_arn,
                            "current_lag_seconds": current_lag,
                            "threshold_seconds": self._max_lag_seconds,
                            "severity": "WARNING",
                            "message": (
                                f"CDC replication lag ({current_lag:.1f}s) "
                                f"exceeds threshold ({self._max_lag_seconds}s)"
                            ),
                            "timestamp": datetime.utcnow().isoformat(),
                        }),
                        "EventBusName": self._event_bus_name,
                    }
                ]
            )
            logger.info("Emitted CDC lag warning event (lag=%.1fs)", current_lag)
        except ClientError as e:
            logger.error("Failed to emit lag warning event: %s", str(e))

    def _scale_up_instance(self) -> dict[str, Any]:
        """Scale up the DMS replication instance to the next tier.

        Requirement 5.4: Scale DMS replication instance capacity.

        Returns:
            Dictionary with scale operation details.
        """
        try:
            current_class = self._get_current_instance_class()
            new_class = _INSTANCE_SCALE_UP_PATH.get(current_class)

            if new_class is None:
                logger.warning(
                    "Instance %s is already at maximum size, cannot scale up",
                    current_class,
                )
                return {
                    "success": False,
                    "reason": "already_at_max",
                    "current_class": current_class,
                }

            self._dms_client.modify_replication_instance(
                ReplicationInstanceArn=self._replication_instance_arn,
                ReplicationInstanceClass=new_class,
                ApplyImmediately=True,
            )

            logger.info(
                "Scaling DMS instance from %s to %s",
                current_class,
                new_class,
            )
            return {
                "success": True,
                "previous_class": current_class,
                "new_class": new_class,
            }

        except ClientError as e:
            logger.error("Failed to scale up DMS instance: %s", str(e))
            return {"success": False, "reason": str(e)}


    def _get_current_instance_class(self) -> str:
        """Retrieve the current instance class of the DMS replication instance."""
        try:
            response = self._dms_client.describe_replication_instances(
                Filters=[
                    {
                        "Name": "replication-instance-arn",
                        "Values": [self._replication_instance_arn],
                    }
                ]
            )
            instances = response.get("ReplicationInstances", [])
            if instances:
                return instances[0]["ReplicationInstanceClass"]
            return "dms.r6i.2xlarge"  # Default assumption
        except ClientError as e:
            logger.error(
                "Failed to describe replication instance: %s", str(e)
            )
            return "dms.r6i.2xlarge"

    def _get_instance_id(self) -> str:
        """Extract instance identifier from ARN."""
        # ARN format: arn:aws:dms:region:account:rep:INSTANCE_ID
        parts = self._replication_instance_arn.split(":")
        if len(parts) >= 7:
            return parts[-1]
        return self._replication_instance_arn

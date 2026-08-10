"""EventBridge event schemas as Python dataclasses.

Defines typed models for all domain events flowing through the
verticalbroker-platform EventBridge bus:
- DataIngestedEvent: Market data successfully ingested to Bronze
- TradeExecutedEvent: Trade order executed
- PipelineFailedEvent: ETL pipeline execution failed
- ComplianceAlertEvent: Security/compliance issue detected
- AdvisoryGeneratedEvent: RL advisory recommendation produced

All events follow the EventBridge envelope pattern with source,
detail-type, and structured detail payload.

Requirements: 6.2 - Event patterns: data.ingested, trade.executed,
             pipeline.failed, compliance.alert, advisory.generated
"""

from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Dict, List, Optional
from uuid import uuid4


@dataclass
class BaseEvent:
    """Base class for all EventBridge events.

    Provides common envelope fields used by all platform events.
    """

    source: str = ""
    detail_type: str = ""
    event_bus_name: str = "verticalbroker-platform"

    def to_eventbridge_entry(self) -> Dict[str, Any]:
        """Convert to EventBridge PutEvents entry format.

        Returns:
            Dictionary compatible with EventBridge PutEvents API.
        """
        import json

        return {
            "Source": self.source,
            "DetailType": self.detail_type,
            "Detail": json.dumps(self.to_detail()),
            "EventBusName": self.event_bus_name,
        }

    def to_detail(self) -> Dict[str, Any]:
        """Convert event-specific fields to detail payload.

        Must be implemented by subclasses.
        """
        raise NotImplementedError


@dataclass
class DataIngestedEvent(BaseEvent):
    """Event emitted when market data is successfully ingested to Bronze layer.

    Source: verticalbroker.market-data
    Detail-type: MarketDataIngested
    """

    source_id: str = ""  # bloomberg_bpipe | thomson_reuters
    partition_path: str = ""  # S3 partition path
    record_count: int = 0
    ingestion_timestamp: str = ""  # ISO-8601
    schema_version: str = ""
    size_bytes: int = 0

    def __post_init__(self):
        self.source = "verticalbroker.market-data"
        self.detail_type = "MarketDataIngested"
        if not self.ingestion_timestamp:
            self.ingestion_timestamp = datetime.now(timezone.utc).isoformat()

    def to_detail(self) -> Dict[str, Any]:
        return {
            "source_id": self.source_id,
            "partition_path": self.partition_path,
            "record_count": self.record_count,
            "ingestion_timestamp": self.ingestion_timestamp,
            "schema_version": self.schema_version,
            "size_bytes": self.size_bytes,
        }


@dataclass
class TradeExecutedEvent(BaseEvent):
    """Event emitted when a trade order is executed.

    Source: verticalbroker.order-manager
    Detail-type: TradeExecuted
    """

    order_id: str = ""  # UUID
    client_id: str = ""
    instrument_id: str = ""  # ISIN/CUSIP
    side: str = ""  # BUY | SELL
    quantity: Decimal = Decimal("0")
    executed_price: Decimal = Decimal("0")
    execution_timestamp: str = ""  # ISO-8601
    venue: str = ""  # Exchange or dark pool

    def __post_init__(self):
        self.source = "verticalbroker.order-manager"
        self.detail_type = "TradeExecuted"
        if not self.execution_timestamp:
            self.execution_timestamp = datetime.now(timezone.utc).isoformat()

    def to_detail(self) -> Dict[str, Any]:
        return {
            "order_id": self.order_id,
            "client_id": self.client_id,
            "instrument_id": self.instrument_id,
            "side": self.side,
            "quantity": float(self.quantity),
            "executed_price": float(self.executed_price),
            "execution_timestamp": self.execution_timestamp,
            "venue": self.venue,
        }


@dataclass
class PipelineFailedEvent(BaseEvent):
    """Event emitted when an ETL pipeline execution fails.

    Source: verticalbroker.etl-engine
    Detail-type: PipelineExecutionFailed
    """

    job_id: str = ""
    pipeline_stage: str = ""  # bronze-to-silver | silver-to-gold
    error_type: str = ""
    error_message: str = ""
    retry_count: int = 0
    affected_partitions: List[str] = field(default_factory=list)
    failure_timestamp: str = ""  # ISO-8601

    def __post_init__(self):
        self.source = "verticalbroker.etl-engine"
        self.detail_type = "PipelineExecutionFailed"
        if not self.failure_timestamp:
            self.failure_timestamp = datetime.now(timezone.utc).isoformat()

    def to_detail(self) -> Dict[str, Any]:
        return {
            "job_id": self.job_id,
            "pipeline_stage": self.pipeline_stage,
            "error_type": self.error_type,
            "error_message": self.error_message,
            "retry_count": self.retry_count,
            "affected_partitions": self.affected_partitions,
            "failure_timestamp": self.failure_timestamp,
        }


@dataclass
class ComplianceAlertEvent(BaseEvent):
    """Event emitted when a security/compliance issue is detected.

    Source: verticalbroker.security
    Detail-type: ComplianceAlert
    """

    alert_id: str = ""  # UUID
    severity: str = ""  # HIGH | MEDIUM | LOW
    alert_type: str = ""
    source_account: str = ""
    resource_arn: str = ""
    description: str = ""
    detection_timestamp: str = ""  # ISO-8601

    def __post_init__(self):
        self.source = "verticalbroker.security"
        self.detail_type = "ComplianceAlert"
        if not self.alert_id:
            self.alert_id = str(uuid4())
        if not self.detection_timestamp:
            self.detection_timestamp = datetime.now(timezone.utc).isoformat()

    def to_detail(self) -> Dict[str, Any]:
        return {
            "alert_id": self.alert_id,
            "severity": self.severity,
            "alert_type": self.alert_type,
            "source_account": self.source_account,
            "resource_arn": self.resource_arn,
            "description": self.description,
            "detection_timestamp": self.detection_timestamp,
        }


@dataclass
class AdvisoryGeneratedEvent(BaseEvent):
    """Event emitted when an RL advisory recommendation is produced.

    Source: verticalbroker.advisory-agent
    Detail-type: AdvisoryGenerated
    """

    recommendation_id: str = ""  # UUID
    client_id: str = ""
    model_version: str = ""
    confidence_score: float = 0.0
    requires_human_review: bool = False
    timestamp: str = ""  # ISO-8601

    def __post_init__(self):
        self.source = "verticalbroker.advisory-agent"
        self.detail_type = "AdvisoryGenerated"
        if not self.recommendation_id:
            self.recommendation_id = str(uuid4())
        if not self.timestamp:
            self.timestamp = datetime.now(timezone.utc).isoformat()

    def to_detail(self) -> Dict[str, Any]:
        return {
            "recommendation_id": self.recommendation_id,
            "client_id": self.client_id,
            "model_version": self.model_version,
            "confidence_score": self.confidence_score,
            "requires_human_review": self.requires_human_review,
            "timestamp": self.timestamp,
        }


__all__ = [
    "BaseEvent",
    "DataIngestedEvent",
    "TradeExecutedEvent",
    "PipelineFailedEvent",
    "ComplianceAlertEvent",
    "AdvisoryGeneratedEvent",
]

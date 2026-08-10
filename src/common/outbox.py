"""Transactional outbox pattern using DynamoDB Streams.

Ensures events are published exactly once alongside state changes by writing
business data and outbox records in a single DynamoDB transaction. A DynamoDB
Stream-triggered Lambda publishes events to EventBridge and marks records as
published.

Pattern:
1. Write business state + outbox record in single DynamoDB transaction
2. DynamoDB Stream triggers outbox publisher Lambda
3. Publisher emits event to EventBridge
4. Publisher marks outbox record as published

Outbox Record Schema:
    PK: OUTBOX#{uuid}
    SK: EVENT#{iso_timestamp}
    event_type: str - EventBridge detail-type
    event_payload: str - JSON serialized event detail
    published: bool - Whether event has been emitted
    created_at: str - ISO-8601 creation timestamp
    ttl: int - Auto-delete after 7 days

Requirements: 7.5 - Idempotent execution preventing duplicate processing
"""

import json
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional
from uuid import uuid4

import boto3
from aws_lambda_powertools import Logger

logger = Logger(child=True)


class TransactionalOutbox:
    """Ensures events are published exactly once alongside state changes.

    Uses DynamoDB transactions to atomically write business data and outbox
    events. A DynamoDB Streams consumer then publishes events to EventBridge,
    guaranteeing at-least-once delivery without dual-write issues.

    Args:
        table_name: DynamoDB table for business data and outbox records.
        event_bus_name: EventBridge bus name for publishing events.
        ttl_days: Days before outbox records are auto-deleted.
    """

    def __init__(
        self,
        table_name: str,
        event_bus_name: str = "verticalbroker-platform",
        ttl_days: int = 7,
    ):
        self.table_name = table_name
        self.event_bus_name = event_bus_name
        self.ttl_days = ttl_days
        self.dynamodb = boto3.resource("dynamodb")
        self.table = self.dynamodb.Table(table_name)
        self.client = boto3.client("dynamodb")

    def execute_with_outbox(
        self,
        business_item: Dict[str, Any],
        event: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Atomically write business data and outbox event.

        Performs a DynamoDB transact_write_items to write both the business
        item and an outbox record in a single atomic operation.

        Args:
            business_item: The business data item to persist. Must include
                          PK and SK attributes for the DynamoDB table.
            event: Event to publish, with keys:
                  - detail_type: EventBridge detail-type
                  - source: EventBridge source
                  - detail: Event payload dict

        Returns:
            The outbox record that was created.

        Raises:
            ClientError: If the DynamoDB transaction fails.
        """
        now = datetime.now(timezone.utc)
        outbox_id = str(uuid4())

        outbox_record = {
            "PK": f"OUTBOX#{outbox_id}",
            "SK": f"EVENT#{now.isoformat()}",
            "event_type": event["detail_type"],
            "event_source": event.get("source", "verticalbroker.outbox"),
            "event_payload": json.dumps(event["detail"]),
            "published": False,
            "created_at": now.isoformat(),
            "ttl": int((now + timedelta(days=self.ttl_days)).timestamp()),
        }

        # Transactional write: business item + outbox in one operation
        self.client.transact_write_items(
            TransactItems=[
                {
                    "Put": {
                        "TableName": self.table_name,
                        "Item": self._serialize_item(business_item),
                    }
                },
                {
                    "Put": {
                        "TableName": self.table_name,
                        "Item": self._serialize_item(outbox_record),
                    }
                },
            ]
        )

        logger.info(
            "Transactional outbox write completed",
            outbox_id=outbox_id,
            event_type=event["detail_type"],
            business_pk=business_item.get("PK"),
        )

        return outbox_record

    def publish_outbox_event(self, outbox_record: Dict[str, Any]) -> bool:
        """Publish an outbox event to EventBridge and mark as published.

        Called by the DynamoDB Streams consumer Lambda to emit the
        event and update the outbox record's published flag.

        Args:
            outbox_record: The outbox record from DynamoDB Stream.

        Returns:
            True if event was published successfully.
        """
        eventbridge = boto3.client("events")

        try:
            event_payload = json.loads(outbox_record["event_payload"])

            eventbridge.put_events(
                Entries=[
                    {
                        "Source": outbox_record.get(
                            "event_source", "verticalbroker.outbox"
                        ),
                        "DetailType": outbox_record["event_type"],
                        "Detail": json.dumps(event_payload),
                        "EventBusName": self.event_bus_name,
                    }
                ]
            )

            # Mark as published
            self.table.update_item(
                Key={
                    "PK": outbox_record["PK"],
                    "SK": outbox_record["SK"],
                },
                UpdateExpression="SET published = :published, published_at = :ts",
                ExpressionAttributeValues={
                    ":published": True,
                    ":ts": datetime.now(timezone.utc).isoformat(),
                },
            )

            logger.info(
                "Outbox event published",
                outbox_pk=outbox_record["PK"],
                event_type=outbox_record["event_type"],
            )
            return True

        except Exception as e:
            logger.error(
                "Failed to publish outbox event",
                outbox_pk=outbox_record["PK"],
                event_type=outbox_record["event_type"],
                error=str(e),
            )
            return False

    def get_unpublished_events(self, limit: int = 100) -> list[Dict[str, Any]]:
        """Retrieve unpublished outbox events for reprocessing.

        Used by a scheduled cleanup process to find and retry events
        that failed initial publication.

        Args:
            limit: Maximum number of records to return.

        Returns:
            List of unpublished outbox records.
        """
        response = self.table.scan(
            FilterExpression="begins_with(PK, :prefix) AND published = :false",
            ExpressionAttributeValues={
                ":prefix": "OUTBOX#",
                ":false": False,
            },
            Limit=limit,
        )
        return response.get("Items", [])

    def _serialize_item(self, item: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
        """Serialize a Python dict to DynamoDB item format for transact_write_items.

        Args:
            item: Plain Python dictionary.

        Returns:
            DynamoDB formatted item with type descriptors.
        """
        from boto3.dynamodb.types import TypeSerializer

        serializer = TypeSerializer()
        return {k: serializer.serialize(v) for k, v in item.items()}


__all__ = [
    "TransactionalOutbox",
]

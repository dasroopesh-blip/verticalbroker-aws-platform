"""Dead-letter queue processor with alerting and metrics.

Handles messages that have exhausted all retry attempts by:
1. Emitting pipeline.failed event to EventBridge
2. Incrementing DLQ depth CloudWatch metric
3. Logging failure context (source queue, reason, retry count, message ID)

Requirements: 7.6 - Route to dead-letter queue after 3 attempts
             6.5 - Dead-letter queues with max receive count of 5
"""

import json
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import boto3
from aws_lambda_powertools import Logger

logger = Logger(child=True)


class DLQProcessor:
    """Handles messages that exhausted all retry attempts.

    Processes dead-lettered messages by emitting failure events,
    recording CloudWatch metrics, and logging detailed context
    for debugging and operational awareness.

    Args:
        event_bus_name: EventBridge bus for failure events.
        metric_namespace: CloudWatch namespace for DLQ metrics.
    """

    def __init__(
        self,
        event_bus_name: str = "verticalbroker-platform",
        metric_namespace: str = "VerticalBroker/DLQ",
    ):
        self.event_bus_name = event_bus_name
        self.metric_namespace = metric_namespace
        self.eventbridge = boto3.client("events")
        self.cloudwatch = boto3.client("cloudwatch")

    def process_dlq_message(self, message: Dict[str, Any]) -> Dict[str, Any]:
        """Analyze failed message, emit alert, and record metrics.

        Args:
            message: SQS message from the dead-letter queue containing
                     failure context and original message attributes.

        Returns:
            Dict with processing result including failure context.
        """
        failure_context = self._extract_failure_context(message)

        # Log detailed failure information
        logger.error(
            "Message dead-lettered",
            original_queue=failure_context["original_queue"],
            failure_reason=failure_context["failure_reason"],
            retry_count=failure_context["retry_count"],
            message_id=failure_context["message_id"],
            first_received=failure_context["first_received"],
        )

        # Emit pipeline.failed event to EventBridge
        self._emit_failure_event(failure_context)

        # Increment DLQ depth CloudWatch metric
        self._record_metric(failure_context)

        return failure_context

    def process_batch(self, messages: list[Dict[str, Any]]) -> list[Dict[str, Any]]:
        """Process a batch of DLQ messages.

        Args:
            messages: List of SQS messages from the dead-letter queue.

        Returns:
            List of failure contexts for all processed messages.
        """
        results = []
        for message in messages:
            try:
                result = self.process_dlq_message(message)
                results.append(result)
            except Exception as e:
                logger.error(
                    "Failed to process DLQ message",
                    message_id=message.get("MessageId", "unknown"),
                    error=str(e),
                )
                results.append(
                    {
                        "message_id": message.get("MessageId", "unknown"),
                        "processing_error": str(e),
                    }
                )
        return results

    def _extract_failure_context(self, message: Dict[str, Any]) -> Dict[str, Any]:
        """Extract failure context from a dead-lettered message.

        Args:
            message: Raw SQS message from DLQ.

        Returns:
            Structured failure context dictionary.
        """
        attributes = message.get("Attributes", {})
        message_attributes = message.get("MessageAttributes", {})

        # Extract source queue from message attributes if available
        source_queue = "unknown"
        if "SourceQueue" in message_attributes:
            source_queue = message_attributes["SourceQueue"].get(
                "StringValue", "unknown"
            )
        elif "source_queue" in message.get("body_parsed", {}):
            source_queue = message["body_parsed"]["source_queue"]

        return {
            "original_queue": source_queue,
            "failure_reason": message.get("error_message", "Max retries exceeded"),
            "retry_count": int(
                attributes.get("ApproximateReceiveCount", 0)
            ),
            "first_received": attributes.get(
                "SentTimestamp",
                datetime.now(timezone.utc).isoformat(),
            ),
            "message_id": message.get("MessageId", "unknown"),
            "message_group_id": attributes.get("MessageGroupId"),
            "body_preview": str(message.get("Body", ""))[:500],
            "dead_lettered_at": datetime.now(timezone.utc).isoformat(),
        }

    def _emit_failure_event(self, failure_context: Dict[str, Any]) -> None:
        """Emit pipeline.failed event to EventBridge.

        Args:
            failure_context: Structured failure details.
        """
        try:
            self.eventbridge.put_events(
                Entries=[
                    {
                        "Source": "verticalbroker.dlq-processor",
                        "DetailType": "MessageDeadLettered",
                        "Detail": json.dumps(
                            {
                                "original_queue": failure_context["original_queue"],
                                "failure_reason": failure_context["failure_reason"],
                                "retry_count": failure_context["retry_count"],
                                "message_id": failure_context["message_id"],
                                "dead_lettered_at": failure_context["dead_lettered_at"],
                            }
                        ),
                        "EventBusName": self.event_bus_name,
                    }
                ]
            )
            logger.info(
                "Failure event emitted to EventBridge",
                message_id=failure_context["message_id"],
            )
        except Exception as e:
            logger.error(
                "Failed to emit failure event",
                message_id=failure_context["message_id"],
                error=str(e),
            )

    def _record_metric(self, failure_context: Dict[str, Any]) -> None:
        """Increment DLQ depth CloudWatch metric.

        Args:
            failure_context: Structured failure details with queue info.
        """
        try:
            self.cloudwatch.put_metric_data(
                Namespace=self.metric_namespace,
                MetricData=[
                    {
                        "MetricName": "DeadLetteredMessages",
                        "Value": 1,
                        "Unit": "Count",
                        "Dimensions": [
                            {
                                "Name": "Queue",
                                "Value": failure_context["original_queue"],
                            }
                        ],
                    }
                ],
            )
        except Exception as e:
            logger.error(
                "Failed to record DLQ metric",
                queue=failure_context["original_queue"],
                error=str(e),
            )


__all__ = [
    "DLQProcessor",
]

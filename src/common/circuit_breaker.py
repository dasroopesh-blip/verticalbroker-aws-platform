"""DynamoDB-backed distributed circuit breaker for Lambda functions.

Implements the circuit breaker pattern for downstream service calls across
distributed Lambda invocations. State is persisted in DynamoDB to share
circuit state across all function instances.

States:
    CLOSED - Normal operation, requests pass through
    OPEN - Service failing, requests rejected immediately
    HALF_OPEN - Testing recovery, limited requests allowed

Requirements: 16.5 - Circuit-breaker patterns preventing cascade failures
"""

import time
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any, Callable, Optional

import boto3
from aws_lambda_powertools import Logger
from boto3.dynamodb.conditions import Attr

logger = Logger(child=True)


class CircuitState(Enum):
    """Circuit breaker states."""

    CLOSED = "closed"  # Normal operation
    OPEN = "open"  # Failing, reject requests
    HALF_OPEN = "half_open"  # Testing recovery


class CircuitOpenError(Exception):
    """Raised when circuit is open and request is rejected."""

    def __init__(self, service_name: str, recovery_time: Optional[datetime] = None):
        self.service_name = service_name
        self.recovery_time = recovery_time
        message = f"Circuit open for service: {service_name}"
        if recovery_time:
            message += f" (recovery at {recovery_time.isoformat()})"
        super().__init__(message)


class CircuitBreaker:
    """DynamoDB-backed circuit breaker for distributed Lambda functions.

    Tracks failure/success counts in DynamoDB to coordinate circuit state
    across all Lambda instances calling the same downstream service.

    Args:
        service_name: Unique identifier for the downstream service.
        failure_threshold: Number of failures to trip the circuit.
        recovery_timeout: Seconds to wait before trying half-open.
        success_threshold: Successes in half-open to close the circuit.
        table_name: DynamoDB table storing circuit state.
    """

    def __init__(
        self,
        service_name: str,
        failure_threshold: int = 5,
        recovery_timeout: int = 60,
        success_threshold: int = 3,
        table_name: str = "CircuitBreakerState",
    ):
        self.service_name = service_name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = timedelta(seconds=recovery_timeout)
        self.success_threshold = success_threshold
        self.table_name = table_name
        self.dynamodb = boto3.resource("dynamodb")
        self.table = self.dynamodb.Table(table_name)

    def get_state(self) -> CircuitState:
        """Read current circuit state from DynamoDB.

        Returns:
            Current CircuitState for this service.
        """
        try:
            response = self.table.get_item(
                Key={"service_name": self.service_name},
                ConsistentRead=True,
            )
            item = response.get("Item")

            if not item:
                return CircuitState.CLOSED

            state = CircuitState(item.get("state", "closed"))

            # Check if OPEN circuit should transition to HALF_OPEN
            if state == CircuitState.OPEN:
                last_failure_time = datetime.fromisoformat(
                    item.get("last_failure_time", datetime.now(timezone.utc).isoformat())
                )
                if datetime.now(timezone.utc) - last_failure_time >= self.recovery_timeout:
                    self._transition_to_half_open()
                    return CircuitState.HALF_OPEN

            return state

        except Exception as e:
            logger.warning(
                "Failed to read circuit state, defaulting to CLOSED",
                service=self.service_name,
                error=str(e),
            )
            return CircuitState.CLOSED

    def record_success(self) -> None:
        """Record a successful call. May transition HALF_OPEN -> CLOSED."""
        try:
            response = self.table.get_item(
                Key={"service_name": self.service_name},
                ConsistentRead=True,
            )
            item = response.get("Item", {})
            current_state = CircuitState(item.get("state", "closed"))

            if current_state == CircuitState.HALF_OPEN:
                success_count = item.get("half_open_success_count", 0) + 1

                if success_count >= self.success_threshold:
                    # Transition HALF_OPEN -> CLOSED
                    self.table.put_item(
                        Item={
                            "service_name": self.service_name,
                            "state": CircuitState.CLOSED.value,
                            "failure_count": 0,
                            "half_open_success_count": 0,
                            "last_success_time": datetime.now(timezone.utc).isoformat(),
                            "last_state_change": datetime.now(timezone.utc).isoformat(),
                        }
                    )
                    logger.info(
                        "Circuit closed after recovery",
                        service=self.service_name,
                        success_count=success_count,
                    )
                else:
                    # Increment success counter in HALF_OPEN
                    self.table.update_item(
                        Key={"service_name": self.service_name},
                        UpdateExpression="SET half_open_success_count = :sc, last_success_time = :ts",
                        ExpressionAttributeValues={
                            ":sc": success_count,
                            ":ts": datetime.now(timezone.utc).isoformat(),
                        },
                    )
            elif current_state == CircuitState.CLOSED:
                # Reset failure count on success in closed state
                self.table.update_item(
                    Key={"service_name": self.service_name},
                    UpdateExpression="SET failure_count = :zero, last_success_time = :ts",
                    ExpressionAttributeValues={
                        ":zero": 0,
                        ":ts": datetime.now(timezone.utc).isoformat(),
                    },
                )

        except Exception as e:
            logger.warning(
                "Failed to record success in circuit breaker",
                service=self.service_name,
                error=str(e),
            )

    def record_failure(self, error: Optional[Exception] = None) -> None:
        """Record a failed call. May transition CLOSED -> OPEN or HALF_OPEN -> OPEN."""
        try:
            response = self.table.get_item(
                Key={"service_name": self.service_name},
                ConsistentRead=True,
            )
            item = response.get("Item", {})
            current_state = CircuitState(item.get("state", "closed"))
            now = datetime.now(timezone.utc).isoformat()

            if current_state == CircuitState.HALF_OPEN:
                # Any failure in HALF_OPEN immediately opens the circuit
                self.table.put_item(
                    Item={
                        "service_name": self.service_name,
                        "state": CircuitState.OPEN.value,
                        "failure_count": self.failure_threshold,
                        "half_open_success_count": 0,
                        "last_failure_time": now,
                        "last_failure_error": str(error) if error else "Unknown",
                        "last_state_change": now,
                    }
                )
                logger.warning(
                    "Circuit re-opened from half-open",
                    service=self.service_name,
                    error=str(error),
                )
            elif current_state == CircuitState.CLOSED:
                failure_count = item.get("failure_count", 0) + 1

                if failure_count >= self.failure_threshold:
                    # Transition CLOSED -> OPEN
                    self.table.put_item(
                        Item={
                            "service_name": self.service_name,
                            "state": CircuitState.OPEN.value,
                            "failure_count": failure_count,
                            "half_open_success_count": 0,
                            "last_failure_time": now,
                            "last_failure_error": str(error) if error else "Unknown",
                            "last_state_change": now,
                        }
                    )
                    logger.warning(
                        "Circuit opened due to failures",
                        service=self.service_name,
                        failure_count=failure_count,
                        threshold=self.failure_threshold,
                    )
                else:
                    # Increment failure count
                    self.table.update_item(
                        Key={"service_name": self.service_name},
                        UpdateExpression="SET failure_count = :fc, last_failure_time = :ts, last_failure_error = :err",
                        ExpressionAttributeValues={
                            ":fc": failure_count,
                            ":ts": now,
                            ":err": str(error) if error else "Unknown",
                        },
                    )
            else:
                # Already OPEN - update last failure time
                self.table.update_item(
                    Key={"service_name": self.service_name},
                    UpdateExpression="SET last_failure_time = :ts, last_failure_error = :err",
                    ExpressionAttributeValues={
                        ":ts": now,
                        ":err": str(error) if error else "Unknown",
                    },
                )

        except Exception as e:
            logger.warning(
                "Failed to record failure in circuit breaker",
                service=self.service_name,
                error=str(e),
            )

    def can_execute(self) -> bool:
        """Check if a request should be allowed through the circuit.

        Returns:
            True if request is allowed, False if circuit is open.
        """
        state = self.get_state()
        if state == CircuitState.CLOSED:
            return True
        elif state == CircuitState.OPEN:
            return False
        elif state == CircuitState.HALF_OPEN:
            return True  # Allow probe request
        return False

    def execute(self, func: Callable, *args: Any, **kwargs: Any) -> Any:
        """Execute a function with circuit breaker protection.

        Args:
            func: The callable to execute.
            *args: Positional arguments passed to func.
            **kwargs: Keyword arguments passed to func.

        Returns:
            The return value of func.

        Raises:
            CircuitOpenError: If the circuit is open.
        """
        if not self.can_execute():
            raise CircuitOpenError(self.service_name)

        try:
            result = func(*args, **kwargs)
            self.record_success()
            return result
        except Exception as e:
            self.record_failure(e)
            raise

    def _transition_to_half_open(self) -> None:
        """Transition circuit from OPEN to HALF_OPEN."""
        try:
            self.table.update_item(
                Key={"service_name": self.service_name},
                UpdateExpression="SET #s = :state, half_open_success_count = :zero, last_state_change = :ts",
                ExpressionAttributeNames={"#s": "state"},
                ExpressionAttributeValues={
                    ":state": CircuitState.HALF_OPEN.value,
                    ":zero": 0,
                    ":ts": datetime.now(timezone.utc).isoformat(),
                },
                ConditionExpression=Attr("state").eq(CircuitState.OPEN.value),
            )
            logger.info(
                "Circuit transitioned to half-open",
                service=self.service_name,
            )
        except self.dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            # Another instance already transitioned - this is fine
            pass
        except Exception as e:
            logger.warning(
                "Failed to transition to half-open",
                service=self.service_name,
                error=str(e),
            )

    def reset(self) -> None:
        """Manually reset the circuit to CLOSED state."""
        self.table.put_item(
            Item={
                "service_name": self.service_name,
                "state": CircuitState.CLOSED.value,
                "failure_count": 0,
                "half_open_success_count": 0,
                "last_state_change": datetime.now(timezone.utc).isoformat(),
            }
        )
        logger.info("Circuit manually reset to closed", service=self.service_name)


__all__ = [
    "CircuitBreaker",
    "CircuitState",
    "CircuitOpenError",
]

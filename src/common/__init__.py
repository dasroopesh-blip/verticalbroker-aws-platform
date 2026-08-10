"""Common utilities for VerticalBroker Lambda functions.

Provides shared patterns for resilience, idempotency, and event handling:
- idempotency: DynamoDB-based idempotency using Lambda Powertools
- circuit_breaker: DynamoDB-backed distributed circuit breaker
- retry: Configurable retry with exponential backoff and jitter
- dlq_handler: Dead-letter queue processor with alerting
- outbox: Transactional outbox pattern using DynamoDB Streams

All modules are designed to run in AWS Lambda with Python 3.12 runtime
and expect aws-lambda-powertools and boto3 available via Lambda Layer.
"""

__all__ = [
    # idempotency
    "persistence_layer",
    "config",
    "create_idempotency_config",
    # circuit_breaker
    "CircuitBreaker",
    "CircuitState",
    "CircuitOpenError",
    # retry
    "RetryConfig",
    "retry_with_backoff",
    "MaxRetriesExceededError",
    "ThrottlingException",
    # dlq_handler
    "DLQProcessor",
    # outbox
    "TransactionalOutbox",
]

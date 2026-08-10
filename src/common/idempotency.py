"""DynamoDB-based idempotency implementation using Lambda Powertools.

Provides idempotent execution for Lambda functions to prevent duplicate
processing. Uses DynamoDB as the persistence backend with configurable TTL
and local caching for high-throughput paths.

DynamoDB Table Schema (IdempotencyStore):
    PK: idempotency_key (string) - Client-provided or derived key
    TTL: expiration (number) - Auto-cleanup after 24 hours
    status: INPROGRESS | COMPLETED | EXPIRED
    data: Cached response (compressed JSON)
    in_progress_expiration: Lock timeout (prevents zombie locks)

Requirements: 7.5 - Idempotent execution using DynamoDB-based idempotency tokens
"""

from aws_lambda_powertools.utilities.idempotency import (
    DynamoDBPersistenceLayer,
    IdempotencyConfig,
    idempotent_function,
    idempotent,
)

# DynamoDB persistence layer for idempotency state
# Table: IdempotencyStore with TTL-based auto-expiration
persistence_layer = DynamoDBPersistenceLayer(
    table_name="IdempotencyStore",
    key_attr="idempotency_key",
    expiry_attr="expiration",
    status_attr="status",
    data_attr="data",
    in_progress_expiry_attr="in_progress_expiration",
)

# Idempotency configuration with 24-hour TTL and local caching
config = IdempotencyConfig(
    expires_after_seconds=86400,  # 24 hours TTL
    use_local_cache=True,  # In-memory cache for hot path performance
    local_cache_max_items=1000,  # Cache up to 1000 recent idempotency keys
    event_key_jmespath="powertools_json(body).idempotency_key",
    raise_on_no_idempotency_key=True,
)


def create_idempotency_config(
    table_name: str = "IdempotencyStore",
    expires_after_seconds: int = 86400,
    event_key_jmespath: str = "powertools_json(body).idempotency_key",
    local_cache_max_items: int = 1000,
) -> tuple[DynamoDBPersistenceLayer, IdempotencyConfig]:
    """Create a custom idempotency configuration for a specific use case.

    Args:
        table_name: DynamoDB table name for idempotency state.
        expires_after_seconds: TTL for idempotency records.
        event_key_jmespath: JMESPath expression to extract idempotency key.
        local_cache_max_items: Maximum items in local cache.

    Returns:
        Tuple of (DynamoDBPersistenceLayer, IdempotencyConfig).
    """
    layer = DynamoDBPersistenceLayer(
        table_name=table_name,
        key_attr="idempotency_key",
        expiry_attr="expiration",
        status_attr="status",
        data_attr="data",
        in_progress_expiry_attr="in_progress_expiration",
    )

    idempotency_config = IdempotencyConfig(
        expires_after_seconds=expires_after_seconds,
        use_local_cache=True,
        local_cache_max_items=local_cache_max_items,
        event_key_jmespath=event_key_jmespath,
        raise_on_no_idempotency_key=True,
    )

    return layer, idempotency_config


__all__ = [
    "persistence_layer",
    "config",
    "create_idempotency_config",
    "idempotent_function",
    "idempotent",
    "DynamoDBPersistenceLayer",
    "IdempotencyConfig",
]

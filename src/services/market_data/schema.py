"""Market Data Schema Validation.

Validates incoming market data records against required schema, ensures field
types are correct, and checks value constraints for Bloomberg/Thomson Reuters feeds.

Requirements: 1.5, 1.6
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

# Valid source identifiers per design
VALID_SOURCES = {"bloomberg", "thomson-reuters"}

# Required fields for market data records
REQUIRED_FIELDS = {"source_id", "instrument_id", "timestamp"}

# Current schema version
CURRENT_SCHEMA_VERSION = "v2.3.1"

# Instrument ID patterns (ISIN: 12 chars alphanumeric, CUSIP: 9 chars alphanumeric)
ISIN_LENGTH = 12
CUSIP_LENGTH = 9


class SchemaValidationError(Exception):
    """Raised when a record fails schema validation."""

    def __init__(self, field: str, reason: str, record: dict | None = None):
        self.field = field
        self.reason = reason
        self.record = record
        super().__init__(f"Schema validation failed: field='{field}', reason='{reason}'")


def validate_record(record: dict[str, Any]) -> list[SchemaValidationError]:
    """Validate a market data record against the required schema.

    Checks:
    - All required fields are present
    - source_id is a valid source identifier
    - instrument_id matches ISIN or CUSIP format
    - timestamp is a valid ISO-8601 datetime string

    Args:
        record: Raw market data record dict.

    Returns:
        List of validation errors. Empty list means record is valid.
    """
    errors: list[SchemaValidationError] = []

    # Check required fields presence
    for field in REQUIRED_FIELDS:
        if field not in record or record[field] is None:
            errors.append(
                SchemaValidationError(
                    field=field,
                    reason=f"Required field '{field}' is missing or null",
                    record=record,
                )
            )

    # If required fields are missing, skip type/value checks
    if errors:
        return errors

    # Validate source_id
    source_id = record["source_id"]
    if not isinstance(source_id, str):
        errors.append(
            SchemaValidationError(
                field="source_id",
                reason=f"Expected string, got {type(source_id).__name__}",
                record=record,
            )
        )
    elif source_id not in VALID_SOURCES:
        errors.append(
            SchemaValidationError(
                field="source_id",
                reason=f"Invalid source_id '{source_id}'. Must be one of: {VALID_SOURCES}",
                record=record,
            )
        )

    # Validate instrument_id
    instrument_id = record["instrument_id"]
    if not isinstance(instrument_id, str):
        errors.append(
            SchemaValidationError(
                field="instrument_id",
                reason=f"Expected string, got {type(instrument_id).__name__}",
                record=record,
            )
        )
    elif not _is_valid_instrument_id(instrument_id):
        errors.append(
            SchemaValidationError(
                field="instrument_id",
                reason=(
                    f"Invalid instrument_id '{instrument_id}'. "
                    f"Must be ISIN ({ISIN_LENGTH} chars) or CUSIP ({CUSIP_LENGTH} chars) alphanumeric."
                ),
                record=record,
            )
        )

    # Validate timestamp
    timestamp = record["timestamp"]
    if isinstance(timestamp, str):
        parsed_ts = _parse_timestamp(timestamp)
        if parsed_ts is None:
            errors.append(
                SchemaValidationError(
                    field="timestamp",
                    reason=f"Invalid timestamp format: '{timestamp}'. Expected ISO-8601 UTC.",
                    record=record,
                )
            )
    elif not isinstance(timestamp, datetime):
        errors.append(
            SchemaValidationError(
                field="timestamp",
                reason=f"Expected ISO-8601 string or datetime, got {type(timestamp).__name__}",
                record=record,
            )
        )

    return errors


def _is_valid_instrument_id(instrument_id: str) -> bool:
    """Check if instrument_id matches ISIN (12 chars) or CUSIP (9 chars) format."""
    if not instrument_id:
        return False
    length = len(instrument_id)
    if length not in (ISIN_LENGTH, CUSIP_LENGTH):
        return False
    return instrument_id.isalnum()


def _parse_timestamp(timestamp_str: str) -> datetime | None:
    """Parse an ISO-8601 timestamp string to datetime.

    Accepts formats like:
    - 2024-01-15T10:30:00Z
    - 2024-01-15T10:30:00.123Z
    - 2024-01-15T10:30:00+00:00

    Returns:
        Parsed datetime in UTC, or None if parsing fails.
    """
    try:
        dt = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        return dt.astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def parse_timestamp(timestamp_value: str | datetime) -> datetime:
    """Parse a timestamp value (string or datetime) to UTC datetime.

    Args:
        timestamp_value: ISO-8601 string or datetime object.

    Returns:
        UTC datetime.

    Raises:
        SchemaValidationError: If the timestamp cannot be parsed.
    """
    if isinstance(timestamp_value, datetime):
        if timestamp_value.tzinfo is None:
            return timestamp_value.replace(tzinfo=timezone.utc)
        return timestamp_value.astimezone(timezone.utc)

    parsed = _parse_timestamp(timestamp_value)
    if parsed is None:
        raise SchemaValidationError(
            field="timestamp",
            reason=f"Cannot parse timestamp: '{timestamp_value}'",
        )
    return parsed

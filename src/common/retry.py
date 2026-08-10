"""Configurable retry with exponential backoff and jitter.

Provides a decorator-based retry mechanism for transient failures with
exponential backoff, jitter to prevent thundering herd, and configurable
retryable exception types.

Requirements: 7.6 - Retry with exponential backoff (base 1 second, max 5 minutes)
              and route to dead-letter queue after 3 attempts
"""

import random
import time
from dataclasses import dataclass, field
from functools import wraps
from typing import Any, Callable, Optional, Tuple, Type

from aws_lambda_powertools import Logger

logger = Logger(child=True)


class MaxRetriesExceededError(Exception):
    """Raised when all retry attempts have been exhausted.

    Attributes:
        last_exception: The final exception that triggered this error.
        attempts: Total number of attempts made.
    """

    def __init__(self, last_exception: Exception, attempts: int = 0):
        self.last_exception = last_exception
        self.attempts = attempts
        super().__init__(
            f"Max retries exceeded after {attempts} attempts. "
            f"Last error: {last_exception}"
        )


class ThrottlingException(Exception):
    """Exception for AWS throttling errors."""

    pass


@dataclass
class RetryConfig:
    """Configuration for retry behavior.

    Attributes:
        base_delay: Initial delay in seconds before first retry.
        max_delay: Maximum delay cap in seconds (5 minutes).
        max_attempts: Total number of attempts before giving up.
        backoff_factor: Exponential multiplier for delay calculation.
        jitter: Whether to add randomization to prevent thundering herd.
        retryable_exceptions: Tuple of exception types that trigger retries.
    """

    base_delay: float = 1.0
    max_delay: float = 300.0  # 5 minutes maximum
    max_attempts: int = 3
    backoff_factor: float = 2.0
    jitter: bool = True
    retryable_exceptions: Tuple[Type[Exception], ...] = field(
        default_factory=lambda: (
            ConnectionError,
            TimeoutError,
            ThrottlingException,
        )
    )


def calculate_delay(
    attempt: int,
    base_delay: float,
    max_delay: float,
    backoff_factor: float,
    jitter: bool,
) -> float:
    """Calculate the delay for a given retry attempt.

    Uses exponential backoff with optional jitter:
        delay = min(base_delay * (backoff_factor ** attempt), max_delay)
        if jitter: delay *= random.uniform(0.5, 1.5)

    Args:
        attempt: Zero-indexed attempt number.
        base_delay: Base delay in seconds.
        max_delay: Maximum delay cap.
        backoff_factor: Exponential multiplier.
        jitter: Whether to apply randomization.

    Returns:
        Calculated delay in seconds.
    """
    delay = min(base_delay * (backoff_factor ** attempt), max_delay)
    if jitter:
        delay *= random.uniform(0.5, 1.5)
    return delay


def retry_with_backoff(config: Optional[RetryConfig] = None) -> Callable:
    """Decorator for retry with exponential backoff.

    Wraps a function to automatically retry on specified transient exceptions
    with exponential backoff between attempts.

    Args:
        config: RetryConfig instance. Uses defaults if None.

    Returns:
        Decorated function with retry behavior.

    Raises:
        MaxRetriesExceededError: When all retry attempts are exhausted.

    Example:
        @retry_with_backoff(RetryConfig(max_attempts=5, base_delay=2.0))
        def call_external_service():
            response = requests.get("https://api.example.com/data")
            response.raise_for_status()
            return response.json()
    """
    if config is None:
        config = RetryConfig()

    def decorator(func: Callable) -> Callable:
        @wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            last_exception: Optional[Exception] = None

            for attempt in range(config.max_attempts):
                try:
                    return func(*args, **kwargs)
                except config.retryable_exceptions as e:
                    last_exception = e

                    if attempt < config.max_attempts - 1:
                        delay = calculate_delay(
                            attempt=attempt,
                            base_delay=config.base_delay,
                            max_delay=config.max_delay,
                            backoff_factor=config.backoff_factor,
                            jitter=config.jitter,
                        )
                        logger.warning(
                            "Retryable error occurred, backing off",
                            function=func.__name__,
                            attempt=attempt + 1,
                            max_attempts=config.max_attempts,
                            delay_seconds=round(delay, 2),
                            error_type=type(e).__name__,
                            error=str(e),
                        )
                        time.sleep(delay)
                    else:
                        logger.error(
                            "All retry attempts exhausted",
                            function=func.__name__,
                            total_attempts=config.max_attempts,
                            error_type=type(e).__name__,
                            error=str(e),
                        )

            # All retries exhausted - raise for DLQ routing
            raise MaxRetriesExceededError(last_exception, attempts=config.max_attempts)

        return wrapper

    return decorator


__all__ = [
    "RetryConfig",
    "retry_with_backoff",
    "calculate_delay",
    "MaxRetriesExceededError",
    "ThrottlingException",
]

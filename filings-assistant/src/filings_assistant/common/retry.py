"""Configurable retry with exponential backoff and jitter.

Adapted from the VerticalBroker platform (``src/common/retry.py``). Provides a
decorator for retrying transient failures (network, throttling) with
exponential backoff + jitter to avoid thundering-herd on Bedrock/OpenSearch.
"""

from __future__ import annotations

import random
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from functools import wraps
from typing import Any

from filings_assistant.common.logging import get_logger

logger = get_logger("common.retry")


class MaxRetriesExceededError(Exception):
    """Raised when all retry attempts have been exhausted."""

    def __init__(self, last_exception: Exception | None, attempts: int = 0) -> None:
        self.last_exception = last_exception
        self.attempts = attempts
        super().__init__(f"Max retries exceeded after {attempts} attempts. Last error: {last_exception}")


class ThrottlingException(Exception):
    """Raised for throttling-type errors that should be retried."""


@dataclass
class RetryConfig:
    """Configuration for retry behavior."""

    base_delay: float = 1.0
    max_delay: float = 60.0
    max_attempts: int = 3
    backoff_factor: float = 2.0
    jitter: bool = True
    retryable_exceptions: tuple[type[Exception], ...] = field(
        default_factory=lambda: (ConnectionError, TimeoutError, ThrottlingException)
    )


def calculate_delay(attempt: int, base_delay: float, max_delay: float, backoff_factor: float, jitter: bool) -> float:
    """Return exponential-backoff delay (seconds) for a zero-indexed attempt."""
    delay = min(base_delay * (backoff_factor**attempt), max_delay)
    if jitter:
        delay *= random.uniform(0.5, 1.5)
    return delay


def retry_with_backoff(config: RetryConfig | None = None) -> Callable:
    """Decorator: retry a function on transient exceptions with backoff."""
    cfg = config or RetryConfig()

    def decorator(func: Callable) -> Callable:
        @wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            last_exception: Exception | None = None
            for attempt in range(cfg.max_attempts):
                try:
                    return func(*args, **kwargs)
                except cfg.retryable_exceptions as exc:
                    last_exception = exc
                    if attempt < cfg.max_attempts - 1:
                        delay = calculate_delay(
                            attempt, cfg.base_delay, cfg.max_delay, cfg.backoff_factor, cfg.jitter
                        )
                        logger.warning(
                            "Retryable error, backing off",
                            function=func.__name__,
                            attempt=attempt + 1,
                            max_attempts=cfg.max_attempts,
                            delay_seconds=round(delay, 2),
                            error=str(exc),
                        )
                        time.sleep(delay)
                    else:
                        logger.error(
                            "All retry attempts exhausted",
                            function=func.__name__,
                            total_attempts=cfg.max_attempts,
                            error=str(exc),
                        )
            raise MaxRetriesExceededError(last_exception, attempts=cfg.max_attempts)

        return wrapper

    return decorator


__all__ = ["RetryConfig", "retry_with_backoff", "calculate_delay", "MaxRetriesExceededError", "ThrottlingException"]

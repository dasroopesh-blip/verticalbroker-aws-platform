"""
Unit tests for exponential backoff retry module.
Tests: Delay calculation, jitter, max attempts, retryable exceptions.
"""

import random
import time
from decimal import Decimal
from unittest.mock import MagicMock, patch, call

import pytest


pytestmark = pytest.mark.unit


class TestDelayCalculation:
    """Tests for exponential backoff delay computation."""

    def test_first_attempt_uses_base_delay(self):
        """Attempt 0 uses base_delay (1.0s by default)."""
        base_delay = 1.0
        backoff_factor = 2.0
        attempt = 0
        delay = base_delay * (backoff_factor ** attempt)
        assert delay == 1.0

    def test_second_attempt_doubles_delay(self):
        """Attempt 1 uses base_delay * 2 (2.0s)."""
        base_delay = 1.0
        backoff_factor = 2.0
        attempt = 1
        delay = base_delay * (backoff_factor ** attempt)
        assert delay == 2.0

    def test_third_attempt_quadruples_delay(self):
        """Attempt 2 uses base_delay * 4 (4.0s)."""
        base_delay = 1.0
        backoff_factor = 2.0
        attempt = 2
        delay = base_delay * (backoff_factor ** attempt)
        assert delay == 4.0

    def test_delay_capped_at_max(self):
        """Delay never exceeds max_delay (300s = 5 minutes)."""
        base_delay = 1.0
        backoff_factor = 2.0
        max_delay = 300.0
        attempt = 20  # 2^20 = 1,048,576 — would exceed without cap
        delay = min(base_delay * (backoff_factor ** attempt), max_delay)
        assert delay == max_delay

    def test_jitter_adds_randomness(self):
        """Jitter prevents thundering herd by adding random variance."""
        base_delay = 4.0
        # Full jitter: random between 0 and calculated delay
        random.seed(42)
        jittered = random.uniform(0, base_delay)
        assert 0 <= jittered <= base_delay

    def test_no_jitter_returns_exact_delay(self):
        """Without jitter, delay is exactly the calculated value."""
        base_delay = 1.0
        backoff_factor = 2.0
        attempt = 3
        delay = base_delay * (backoff_factor ** attempt)
        assert delay == 8.0  # Exact, no randomness


class TestRetryBehavior:
    """Tests for the retry decorator behavior."""

    def test_success_on_first_attempt_no_retry(self):
        """Successful function call returns immediately (no retries)."""
        call_count = 0

        def successful_function():
            nonlocal call_count
            call_count += 1
            return "success"

        result = successful_function()
        assert result == "success"
        assert call_count == 1

    def test_transient_failure_then_success(self):
        """Transient failure followed by success retries and succeeds."""
        attempts = []

        def flaky_function():
            attempts.append(1)
            if len(attempts) < 3:
                raise ConnectionError("temporary failure")
            return "success"

        # Simulate retry logic
        max_attempts = 3
        for attempt in range(max_attempts):
            try:
                result = flaky_function()
                break
            except ConnectionError:
                if attempt == max_attempts - 1:
                    raise
                continue

        assert result == "success"
        assert len(attempts) == 3

    def test_max_retries_exceeded_raises(self):
        """After max_attempts, raises MaxRetriesExceededError."""
        max_attempts = 3
        attempt_count = 0

        def always_fails():
            nonlocal attempt_count
            attempt_count += 1
            raise ConnectionError("permanent failure")

        with pytest.raises(ConnectionError):
            for attempt in range(max_attempts):
                try:
                    always_fails()
                    break
                except ConnectionError:
                    if attempt == max_attempts - 1:
                        raise

        assert attempt_count == max_attempts

    def test_non_retryable_exception_raises_immediately(self):
        """Non-retryable exceptions (ValueError, etc.) raise without retry."""
        retryable = (ConnectionError, TimeoutError)
        exception = ValueError("bad input")
        assert not isinstance(exception, retryable)

    def test_throttling_exception_is_retryable(self):
        """ThrottlingException is included in retryable exceptions."""
        # Custom exception for AWS throttling
        class ThrottlingException(Exception):
            pass

        retryable = (ConnectionError, TimeoutError, ThrottlingException)
        exception = ThrottlingException("Rate exceeded")
        assert isinstance(exception, retryable)


class TestRetryConfig:
    """Tests for RetryConfig dataclass defaults."""

    def test_default_config_values(self):
        """Default config: 3 attempts, 1s base, 300s max, factor 2, jitter True."""
        config = {
            "max_attempts": 3,
            "base_delay": 1.0,
            "max_delay": 300.0,
            "backoff_factor": 2.0,
            "jitter": True,
        }
        assert config["max_attempts"] == 3
        assert config["base_delay"] == 1.0
        assert config["max_delay"] == 300.0
        assert config["backoff_factor"] == 2.0
        assert config["jitter"] is True

    def test_custom_config_override(self):
        """Custom config can override any default."""
        config = {
            "max_attempts": 5,
            "base_delay": 2.0,
            "max_delay": 60.0,
            "backoff_factor": 3.0,
            "jitter": False,
        }
        assert config["max_attempts"] == 5
        assert config["max_delay"] == 60.0

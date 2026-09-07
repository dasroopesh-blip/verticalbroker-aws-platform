"""Structured logging helper.

Uses aws-lambda-powertools Logger (JSON structured logs, no ``print``) to match
the VerticalBroker convention. Works fine outside Lambda too.
"""

from __future__ import annotations

from aws_lambda_powertools import Logger


def get_logger(service: str) -> Logger:
    """Return a Powertools Logger scoped to a service name.

    Args:
        service: Logical service name, e.g. ``"ingestion"`` or ``"agent"``.
    """
    return Logger(service=f"filings-assistant.{service}")

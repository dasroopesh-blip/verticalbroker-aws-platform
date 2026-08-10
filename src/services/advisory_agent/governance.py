"""Advisory Agent Governance and FINRA Compliance.

Implements governance rules for the Advisory Agent including:
- Confidence threshold evaluation (flag < 0.7 for human review)
- Uncertainty factor extraction (top 3 factors)
- FINRA compliance logging of ALL recommendations to Regulatory Store
  (S3 Object Lock COMPLIANCE mode per FINRA Rule 4511)

Requirements: 12.5, 12.6, 14.4
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="advisory-agent")

# Governance threshold: recommendations below this confidence
# are flagged for human advisor review
CONFIDENCE_THRESHOLD = 0.7

# Maximum number of uncertainty factors to include in the response
MAX_UNCERTAINTY_FACTORS = 3


class DecimalEncoder(json.JSONEncoder):
    """JSON encoder that handles Decimal types for compliance logging."""

    def default(self, obj: Any) -> Any:
        if isinstance(obj, Decimal):
            return str(obj)
        if isinstance(obj, datetime):
            return obj.isoformat()
        return super().default(obj)


@dataclass
class GovernanceResult:
    """Result of governance evaluation on a recommendation.

    Attributes:
        requires_human_review: True if confidence < 0.7 threshold.
        uncertainty_factors: Top 3 reasons for low confidence.
        governance_notes: Additional governance metadata.
    """

    requires_human_review: bool
    uncertainty_factors: list[str] = field(default_factory=list)
    governance_notes: str = ""


class GovernanceEngine:
    """Evaluates recommendations against governance rules.

    Implements the governance gate that flags low-confidence recommendations
    for human advisor review per Requirement 12.6:
    "IF the Advisory_Agent confidence score falls below 0.7, THEN THE
    Advisory_Agent SHALL flag the recommendation for human advisor review
    and include an explanation of uncertainty factors."
    """

    def __init__(self, confidence_threshold: float = CONFIDENCE_THRESHOLD):
        """Initialize governance engine.

        Args:
            confidence_threshold: Minimum confidence score to pass without
                human review. Default 0.7 per design specification.
        """
        self.confidence_threshold = confidence_threshold

    def evaluate(
        self,
        confidence_score: float,
        model_uncertainty_factors: list[str],
    ) -> GovernanceResult:
        """Evaluate a recommendation against governance rules.

        Args:
            confidence_score: Model confidence score (0.0 - 1.0).
            model_uncertainty_factors: Raw uncertainty factors from the model.

        Returns:
            GovernanceResult with human review flag and top uncertainty factors.
        """
        requires_review = confidence_score < self.confidence_threshold

        # Extract top N uncertainty factors when flagged for review
        uncertainty_factors: list[str] = []
        governance_notes = ""

        if requires_review:
            uncertainty_factors = model_uncertainty_factors[:MAX_UNCERTAINTY_FACTORS]
            governance_notes = (
                f"Confidence score {confidence_score:.4f} is below threshold "
                f"{self.confidence_threshold}. Flagged for human advisor review."
            )
            logger.warning(
                "Recommendation flagged for human review",
                extra={
                    "confidence_score": confidence_score,
                    "threshold": self.confidence_threshold,
                    "uncertainty_factors": uncertainty_factors,
                },
            )

        return GovernanceResult(
            requires_human_review=requires_review,
            uncertainty_factors=uncertainty_factors,
            governance_notes=governance_notes,
        )


class RegulatoryStore:
    """FINRA compliance logging to S3 Regulatory Store.

    Logs ALL recommendations (input features, model version, output allocations,
    confidence scores) to the Regulatory Store using S3 Object Lock COMPLIANCE mode
    per FINRA Rule 4511 (7-year retention).

    Requirement 12.5: "THE Advisory_Agent SHALL log all recommendations with
    input features, model version, output allocations, and confidence scores
    to the Regulatory_Store for FINRA audit compliance."

    Requirement 14.4: "THE Regulatory_Store SHALL retain all trade records, audit
    logs, and communications for 7 years in immutable storage (S3 Object Lock
    Compliance mode) per FINRA Rule 4511."
    """

    def __init__(
        self,
        bucket_name: str | None = None,
        s3_client: Any | None = None,
    ):
        """Initialize regulatory store.

        Args:
            bucket_name: S3 bucket name for regulatory store. Defaults to
                environment variable REGULATORY_STORE_BUCKET.
            s3_client: Optional boto3 S3 client for dependency injection.
        """
        self.bucket_name = bucket_name or os.environ.get(
            "REGULATORY_STORE_BUCKET", "vb-regulatory-store"
        )
        self.s3_client = s3_client or boto3.client("s3")
        self.retention_years = 7  # FINRA Rule 4511

    def log_recommendation(
        self,
        recommendation_id: str,
        client_id: str,
        input_features: dict[str, Any],
        model_version: str,
        output_allocations: dict[str, Any],
        confidence_score: float,
        requires_human_review: bool,
        uncertainty_factors: list[str],
        timestamp: datetime | None = None,
    ) -> str:
        """Log a recommendation to the Regulatory Store with Object Lock COMPLIANCE mode.

        All parameters are persisted for FINRA audit trail. Records are immutable
        once written and retained for 7 years.

        Args:
            recommendation_id: Unique recommendation identifier.
            client_id: Client who received the recommendation.
            input_features: Customer profile features used as model input.
            model_version: Version of the model that produced the recommendation.
            output_allocations: Portfolio allocation percentages by asset class.
            confidence_score: Model confidence score (0.0 - 1.0).
            requires_human_review: Whether governance flagged for human review.
            uncertainty_factors: Uncertainty factors if flagged for review.
            timestamp: Timestamp of the recommendation (defaults to now UTC).

        Returns:
            S3 object key where the compliance record was stored.
        """
        if timestamp is None:
            timestamp = datetime.now(timezone.utc)

        # Build compliance record with full audit trail
        compliance_record = {
            "recommendation_id": recommendation_id,
            "client_id": client_id,
            "timestamp": timestamp.isoformat(),
            "input_features": input_features,
            "model_version": model_version,
            "output": {
                "allocations": output_allocations,
                "confidence_score": confidence_score,
                "requires_human_review": requires_human_review,
                "uncertainty_factors": uncertainty_factors,
            },
            "compliance_metadata": {
                "regulation": "FINRA Rule 4511",
                "retention_years": self.retention_years,
                "record_type": "advisory_recommendation",
                "immutable": True,
                "object_lock_mode": "COMPLIANCE",
            },
        }

        # S3 key: advisory-logs/{year}/{month}/{day}/{recommendation_id}.json
        s3_key = (
            f"advisory-logs/"
            f"{timestamp.strftime('%Y/%m/%d')}/"
            f"{recommendation_id}.json"
        )

        # Write to S3 with Object Lock COMPLIANCE mode
        self.s3_client.put_object(
            Bucket=self.bucket_name,
            Key=s3_key,
            Body=json.dumps(compliance_record, cls=DecimalEncoder),
            ContentType="application/json",
            ObjectLockMode="COMPLIANCE",
            ObjectLockRetainUntilDate=self._calculate_retention_date(timestamp),
        )

        logger.info(
            "FINRA compliance record logged",
            extra={
                "recommendation_id": recommendation_id,
                "client_id": client_id,
                "s3_key": s3_key,
                "object_lock_mode": "COMPLIANCE",
            },
        )

        return s3_key

    def _calculate_retention_date(self, base_date: datetime) -> datetime:
        """Calculate the Object Lock retention date (7 years from base date).

        Args:
            base_date: The base timestamp for retention calculation.

        Returns:
            Datetime 7 years in the future from base_date.
        """
        return base_date.replace(year=base_date.year + self.retention_years)

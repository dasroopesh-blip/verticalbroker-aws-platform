"""Advisory Agent Lambda Handler.

Provides ML-powered automated investment advisory using SageMaker Reinforcement
Learning real-time inference. Orchestrates model invocation, governance evaluation,
FINRA compliance logging, and event emission.

Routes:
    POST /v1/advisory - Generate portfolio allocation recommendation

Concurrency:
    Reserved: 500
    Provisioned: 100

Requirements: 12.1, 12.4, 12.5, 12.6
"""

from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver, Response
from aws_lambda_powertools.event_handler.exceptions import (
    BadRequestError,
    InternalServerError,
    ServiceError,
)
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from src.services.advisory_agent.governance import (
    GovernanceEngine,
    RegulatoryStore,
)

logger = Logger(service="advisory-agent")
tracer = Tracer(service="advisory-agent")
metrics = Metrics(namespace="VerticalBroker/Advisory")
app = APIGatewayHttpResolver()

# --- Validation Constants ---

VALID_TAX_FILING_STATUSES = {
    "SINGLE",
    "MARRIED_JOINT",
    "MARRIED_SEPARATE",
    "HEAD_OF_HOUSEHOLD",
}

VALID_RISK_PROFILES = {
    "CONSERVATIVE",
    "MODERATE",
    "AGGRESSIVE",
    "VERY_AGGRESSIVE",
}

VALID_INVESTMENT_STRATEGIES = {"GROWTH", "VALUE", "INCOME", "INDEX"}

AGE_MIN = 18
AGE_MAX = 120

# SageMaker endpoint timeout threshold (500ms per Requirement 12.4)
SAGEMAKER_TIMEOUT_MS = 500


# --- Data Models ---


@dataclass
class RiskMetrics:
    """Risk metrics associated with a portfolio recommendation.

    Attributes:
        volatility: Expected portfolio volatility (annualized).
        sharpe_ratio: Expected Sharpe ratio of the recommendation.
        max_drawdown: Maximum expected drawdown percentage.
        var_95: Value at Risk at 95% confidence level.
    """

    volatility: float
    sharpe_ratio: float
    max_drawdown: float
    var_95: float


@dataclass
class CustomerProfile:
    """Input features for RL-based advisory model.

    Requirement 12.1: THE Advisory_Agent SHALL accept customer profile inputs
    (age, tax filing status, income, debt, household income, risk profile,
    investment strategies) and produce portfolio allocation recommendations.

    Attributes:
        age: Customer age (18-120).
        tax_filing_status: Tax filing status (SINGLE, MARRIED_JOINT, etc.).
        annual_income: Annual income (>= 0).
        total_debt: Total debt amount (>= 0).
        household_income: Household income (>= 0).
        risk_profile: Investment risk tolerance level.
        investment_strategies: Preferred investment strategies.
        investment_horizon_years: Investment time horizon in years.
        existing_allocations: Current portfolio allocations by asset class.
    """

    age: int
    tax_filing_status: str
    annual_income: Decimal
    total_debt: Decimal
    household_income: Decimal
    risk_profile: str
    investment_strategies: list[str]
    investment_horizon_years: int
    existing_allocations: dict[str, Decimal]

    def to_features(self) -> dict[str, Any]:
        """Convert profile to model input feature vector.

        Returns:
            Dictionary of features suitable for SageMaker endpoint invocation.
        """
        return {
            "age": self.age,
            "tax_filing_status": self.tax_filing_status,
            "annual_income": float(self.annual_income),
            "total_debt": float(self.total_debt),
            "household_income": float(self.household_income),
            "risk_profile": self.risk_profile,
            "investment_strategies": self.investment_strategies,
            "investment_horizon_years": self.investment_horizon_years,
            "existing_allocations": {
                k: float(v) for k, v in self.existing_allocations.items()
            },
        }

    def to_audit_dict(self) -> dict[str, Any]:
        """Convert profile to dictionary for compliance audit logging.

        Returns:
            Dictionary representation suitable for FINRA compliance records.
        """
        return {
            "age": self.age,
            "tax_filing_status": self.tax_filing_status,
            "annual_income": str(self.annual_income),
            "total_debt": str(self.total_debt),
            "household_income": str(self.household_income),
            "risk_profile": self.risk_profile,
            "investment_strategies": self.investment_strategies,
            "investment_horizon_years": self.investment_horizon_years,
            "existing_allocations": {
                k: str(v) for k, v in self.existing_allocations.items()
            },
        }


@dataclass
class AdvisoryRecommendation:
    """Output from RL advisory model with governance annotations.

    Attributes:
        recommendation_id: Unique identifier for this recommendation.
        model_version: Version of the ML model that produced this result.
        allocations: Asset class to percentage mapping (must sum to 100%).
        confidence_score: Model confidence (0.0 - 1.0).
        explanation: Human-readable explanation of the recommendation.
        risk_metrics: Associated risk metrics for the portfolio.
        requires_human_review: True if confidence < 0.7 (governance flag).
        uncertainty_factors: Top factors contributing to low confidence.
    """

    recommendation_id: str
    model_version: str
    allocations: dict[str, Decimal]
    confidence_score: float
    explanation: str
    risk_metrics: RiskMetrics
    requires_human_review: bool = False
    uncertainty_factors: list[str] = field(default_factory=list)

    def to_response_dict(self) -> dict[str, Any]:
        """Convert recommendation to API response dictionary.

        Returns:
            Dictionary suitable for JSON serialization in API response.
        """
        return {
            "recommendation_id": self.recommendation_id,
            "model_version": self.model_version,
            "allocations": {k: str(v) for k, v in self.allocations.items()},
            "confidence_score": self.confidence_score,
            "explanation": self.explanation,
            "risk_metrics": {
                "volatility": self.risk_metrics.volatility,
                "sharpe_ratio": self.risk_metrics.sharpe_ratio,
                "max_drawdown": self.risk_metrics.max_drawdown,
                "var_95": self.risk_metrics.var_95,
            },
            "requires_human_review": self.requires_human_review,
            "uncertainty_factors": self.uncertainty_factors,
        }


# --- Validation ---


def validate_customer_profile(body: dict[str, Any]) -> CustomerProfile:
    """Validate and parse customer profile from request body.

    Validates:
    - age: integer, 18-120
    - tax_filing_status: valid enum value
    - annual_income: numeric, >= 0
    - total_debt: numeric, >= 0
    - household_income: numeric, >= 0
    - risk_profile: valid enum value
    - investment_strategies: non-empty list of valid values
    - investment_horizon_years: positive integer
    - existing_allocations: dict with string keys and numeric values

    Args:
        body: Raw request body dictionary.

    Returns:
        Validated CustomerProfile instance.

    Raises:
        BadRequestError: If any validation rule fails.
    """
    errors: list[str] = []

    # Validate age
    age = body.get("age")
    if age is None:
        errors.append("'age' is required")
    elif not isinstance(age, int):
        errors.append(f"'age' must be an integer, got {type(age).__name__}")
    elif age < AGE_MIN or age > AGE_MAX:
        errors.append(f"'age' must be between {AGE_MIN} and {AGE_MAX}, got {age}")

    # Validate tax_filing_status
    tax_filing_status = body.get("tax_filing_status")
    if tax_filing_status is None:
        errors.append("'tax_filing_status' is required")
    elif tax_filing_status not in VALID_TAX_FILING_STATUSES:
        errors.append(
            f"'tax_filing_status' must be one of {sorted(VALID_TAX_FILING_STATUSES)}, "
            f"got '{tax_filing_status}'"
        )

    # Validate income/debt fields (must be >= 0)
    for field_name in ("annual_income", "total_debt", "household_income"):
        value = body.get(field_name)
        if value is None:
            errors.append(f"'{field_name}' is required")
        else:
            try:
                decimal_val = Decimal(str(value))
                if decimal_val < 0:
                    errors.append(f"'{field_name}' must be >= 0, got {value}")
            except (InvalidOperation, TypeError, ValueError):
                errors.append(
                    f"'{field_name}' must be a valid numeric value, got '{value}'"
                )

    # Validate risk_profile
    risk_profile = body.get("risk_profile")
    if risk_profile is None:
        errors.append("'risk_profile' is required")
    elif risk_profile not in VALID_RISK_PROFILES:
        errors.append(
            f"'risk_profile' must be one of {sorted(VALID_RISK_PROFILES)}, "
            f"got '{risk_profile}'"
        )

    # Validate investment_strategies
    investment_strategies = body.get("investment_strategies")
    if investment_strategies is None:
        errors.append("'investment_strategies' is required")
    elif not isinstance(investment_strategies, list) or len(investment_strategies) == 0:
        errors.append("'investment_strategies' must be a non-empty list")
    else:
        invalid_strategies = set(investment_strategies) - VALID_INVESTMENT_STRATEGIES
        if invalid_strategies:
            errors.append(
                f"'investment_strategies' contains invalid values: {sorted(invalid_strategies)}. "
                f"Valid options: {sorted(VALID_INVESTMENT_STRATEGIES)}"
            )

    # Validate investment_horizon_years
    investment_horizon_years = body.get("investment_horizon_years")
    if investment_horizon_years is None:
        errors.append("'investment_horizon_years' is required")
    elif not isinstance(investment_horizon_years, int) or investment_horizon_years <= 0:
        errors.append(
            "'investment_horizon_years' must be a positive integer, "
            f"got {investment_horizon_years}"
        )

    # Validate existing_allocations
    existing_allocations = body.get("existing_allocations", {})
    if not isinstance(existing_allocations, dict):
        errors.append("'existing_allocations' must be a dictionary")

    # If there are validation errors, raise them all at once
    if errors:
        raise BadRequestError("; ".join(errors))

    # Parse validated values into CustomerProfile
    return CustomerProfile(
        age=age,
        tax_filing_status=tax_filing_status,
        annual_income=Decimal(str(body["annual_income"])),
        total_debt=Decimal(str(body["total_debt"])),
        household_income=Decimal(str(body["household_income"])),
        risk_profile=risk_profile,
        investment_strategies=investment_strategies,
        investment_horizon_years=investment_horizon_years,
        existing_allocations={
            k: Decimal(str(v)) for k, v in existing_allocations.items()
        },
    )


# --- Service Class ---


class AdvisoryAgentService:
    """Orchestrates RL model inference with governance and compliance.

    Implements the full advisory workflow:
    1. Validate customer profile input
    2. Invoke SageMaker endpoint for portfolio recommendation
    3. Apply governance rules (confidence threshold, human review flag)
    4. Log recommendation to FINRA Regulatory Store (S3 Object Lock COMPLIANCE)
    5. Emit advisory.generated event to EventBridge
    6. Return recommendation with correlation ID

    Requirement 12.4: THE Advisory_Agent SHALL return a recommendation within
    500 milliseconds using a SageMaker real-time inference endpoint.
    """

    def __init__(
        self,
        sagemaker_client: Any | None = None,
        eventbridge_client: Any | None = None,
        governance_engine: GovernanceEngine | None = None,
        regulatory_store: RegulatoryStore | None = None,
    ):
        """Initialize the Advisory Agent service.

        Args:
            sagemaker_client: Optional boto3 sagemaker-runtime client.
            eventbridge_client: Optional boto3 EventBridge client.
            governance_engine: Optional GovernanceEngine instance.
            regulatory_store: Optional RegulatoryStore instance.
        """
        self.sagemaker_runtime = sagemaker_client or boto3.client("sagemaker-runtime")
        self.eventbridge_client = eventbridge_client or boto3.client("events")
        self.endpoint_name = os.environ.get("SAGEMAKER_ENDPOINT", "vb-advisory-endpoint")
        self.event_bus_name = os.environ.get(
            "EVENT_BUS_NAME", "verticalbroker-platform"
        )
        self.governance = governance_engine or GovernanceEngine()
        self.regulatory_store = regulatory_store or RegulatoryStore()

    @tracer.capture_method
    def get_recommendation(
        self, profile: CustomerProfile, client_id: str
    ) -> AdvisoryRecommendation:
        """Invoke SageMaker endpoint and apply governance rules.

        Workflow:
        1. Invoke SageMaker real-time endpoint with customer features
        2. Parse model response (allocations, confidence, risk metrics)
        3. Apply governance rules (flag if confidence < 0.7)
        4. Log to FINRA Regulatory Store
        5. Emit advisory.generated event to EventBridge

        Args:
            profile: Validated customer profile with input features.
            client_id: Client identifier for audit trail.

        Returns:
            AdvisoryRecommendation with governance annotations.

        Raises:
            ServiceError: If SageMaker invocation exceeds 500ms timeout.
            InternalServerError: If model response cannot be parsed.
        """
        recommendation_id = str(uuid.uuid4())
        timestamp = datetime.now(timezone.utc)

        # Invoke SageMaker endpoint with timeout tracking
        model_response = self._invoke_sagemaker(profile)

        # Parse model response
        recommendation = self._parse_model_response(
            model_response, recommendation_id
        )

        # Apply governance rules
        governance_result = self.governance.evaluate(
            confidence_score=recommendation.confidence_score,
            model_uncertainty_factors=recommendation.uncertainty_factors,
        )
        recommendation.requires_human_review = governance_result.requires_human_review
        recommendation.uncertainty_factors = governance_result.uncertainty_factors

        # FINRA compliance: log ALL recommendations to Regulatory Store
        self._log_to_regulatory_store(
            recommendation=recommendation,
            profile=profile,
            client_id=client_id,
            timestamp=timestamp,
        )

        # Emit advisory.generated event to EventBridge
        self._emit_advisory_event(
            recommendation=recommendation,
            client_id=client_id,
            timestamp=timestamp,
        )

        # Record metrics
        metrics.add_metric(
            name="RecommendationGenerated", unit=MetricUnit.Count, value=1
        )
        if recommendation.requires_human_review:
            metrics.add_metric(
                name="HumanReviewFlagged", unit=MetricUnit.Count, value=1
            )
        metrics.add_metric(
            name="ConfidenceScore",
            unit=MetricUnit.None_,
            value=recommendation.confidence_score,
        )

        return recommendation

    @tracer.capture_method
    def _invoke_sagemaker(self, profile: CustomerProfile) -> dict[str, Any]:
        """Invoke SageMaker real-time inference endpoint.

        Tracks invocation latency and raises ServiceError if the response
        exceeds the 500ms SLA threshold per Requirement 12.4.

        Args:
            profile: Customer profile with input features.

        Returns:
            Parsed JSON response from SageMaker endpoint.

        Raises:
            ServiceError: If invocation exceeds 500ms timeout.
        """
        start_time = time.time()

        try:
            response = self.sagemaker_runtime.invoke_endpoint(
                EndpointName=self.endpoint_name,
                ContentType="application/json",
                Body=json.dumps(profile.to_features()),
            )
        except self.sagemaker_runtime.exceptions.ModelError as e:
            logger.error("SageMaker model error", extra={"error": str(e)})
            raise InternalServerError("Model inference failed") from e
        except Exception as e:
            logger.error("SageMaker invocation error", extra={"error": str(e)})
            raise InternalServerError("Advisory service unavailable") from e

        elapsed_ms = (time.time() - start_time) * 1000
        metrics.add_metric(
            name="SageMakerLatencyMs", unit=MetricUnit.Milliseconds, value=elapsed_ms
        )

        # Check latency SLA (Requirement 12.4: within 500ms)
        if elapsed_ms > SAGEMAKER_TIMEOUT_MS:
            logger.warning(
                "SageMaker invocation exceeded timeout",
                extra={
                    "elapsed_ms": elapsed_ms,
                    "threshold_ms": SAGEMAKER_TIMEOUT_MS,
                },
            )
            raise ServiceError(
                status_code=504,
                msg="Advisory service timeout. Please retry.",
                headers={"Retry-After": "1"},
            )

        # Parse response body
        response_body = json.loads(response["Body"].read().decode("utf-8"))
        return response_body

    @tracer.capture_method
    def _parse_model_response(
        self, response: dict[str, Any], recommendation_id: str
    ) -> AdvisoryRecommendation:
        """Parse SageMaker model response into AdvisoryRecommendation.

        Args:
            response: Raw JSON response from SageMaker endpoint.
            recommendation_id: Pre-generated recommendation UUID.

        Returns:
            AdvisoryRecommendation with parsed model outputs.

        Raises:
            InternalServerError: If response format is invalid.
        """
        try:
            allocations = {
                k: Decimal(str(v))
                for k, v in response.get("allocations", {}).items()
            }

            risk_data = response.get("risk_metrics", {})
            risk_metrics = RiskMetrics(
                volatility=float(risk_data.get("volatility", 0.0)),
                sharpe_ratio=float(risk_data.get("sharpe_ratio", 0.0)),
                max_drawdown=float(risk_data.get("max_drawdown", 0.0)),
                var_95=float(risk_data.get("var_95", 0.0)),
            )

            return AdvisoryRecommendation(
                recommendation_id=recommendation_id,
                model_version=response.get("model_version", "unknown"),
                allocations=allocations,
                confidence_score=float(response.get("confidence_score", 0.0)),
                explanation=response.get("explanation", ""),
                risk_metrics=risk_metrics,
                uncertainty_factors=response.get("uncertainty_factors", []),
            )
        except (KeyError, TypeError, ValueError) as e:
            logger.error(
                "Failed to parse model response",
                extra={"error": str(e), "response": response},
            )
            raise InternalServerError(
                "Failed to parse advisory model response"
            ) from e

    @tracer.capture_method
    def _log_to_regulatory_store(
        self,
        recommendation: AdvisoryRecommendation,
        profile: CustomerProfile,
        client_id: str,
        timestamp: datetime,
    ) -> str:
        """Log recommendation to FINRA Regulatory Store.

        Writes a complete audit record with Object Lock COMPLIANCE mode.

        Args:
            recommendation: The generated recommendation.
            profile: Input customer profile features.
            client_id: Client identifier.
            timestamp: Timestamp of the recommendation.

        Returns:
            S3 object key of the compliance record.
        """
        return self.regulatory_store.log_recommendation(
            recommendation_id=recommendation.recommendation_id,
            client_id=client_id,
            input_features=profile.to_audit_dict(),
            model_version=recommendation.model_version,
            output_allocations={
                k: str(v) for k, v in recommendation.allocations.items()
            },
            confidence_score=recommendation.confidence_score,
            requires_human_review=recommendation.requires_human_review,
            uncertainty_factors=recommendation.uncertainty_factors,
            timestamp=timestamp,
        )

    @tracer.capture_method
    def _emit_advisory_event(
        self,
        recommendation: AdvisoryRecommendation,
        client_id: str,
        timestamp: datetime,
    ) -> None:
        """Emit advisory.generated event to EventBridge.

        Event schema follows the design specification for advisory.generated:
        source: verticalbroker.advisory-agent
        detail-type: AdvisoryGenerated

        Args:
            recommendation: The generated recommendation.
            client_id: Client identifier.
            timestamp: Timestamp of the recommendation.
        """
        try:
            self.eventbridge_client.put_events(
                Entries=[
                    {
                        "Source": "verticalbroker.advisory-agent",
                        "DetailType": "AdvisoryGenerated",
                        "EventBusName": self.event_bus_name,
                        "Time": timestamp,
                        "Detail": json.dumps(
                            {
                                "recommendation_id": recommendation.recommendation_id,
                                "client_id": client_id,
                                "model_version": recommendation.model_version,
                                "confidence_score": recommendation.confidence_score,
                                "requires_human_review": recommendation.requires_human_review,
                                "timestamp": timestamp.isoformat(),
                            }
                        ),
                    }
                ]
            )
        except Exception as e:
            # EventBridge emission is non-blocking; log and continue
            logger.error(
                "Failed to emit advisory.generated event",
                extra={"error": str(e)},
            )


# --- Route Handlers ---

# Service singleton (initialized once per Lambda container)
_service: AdvisoryAgentService | None = None


def _get_service() -> AdvisoryAgentService:
    """Get or create the AdvisoryAgentService singleton.

    Returns:
        Initialized AdvisoryAgentService instance.
    """
    global _service
    if _service is None:
        _service = AdvisoryAgentService()
    return _service


@app.post("/v1/advisory")
@tracer.capture_method
def post_advisory():
    """POST /v1/advisory - Generate portfolio allocation recommendation.

    Request Body:
        {
            "client_id": "string (required)",
            "age": int (18-120),
            "tax_filing_status": "SINGLE|MARRIED_JOINT|MARRIED_SEPARATE|HEAD_OF_HOUSEHOLD",
            "annual_income": number (>= 0),
            "total_debt": number (>= 0),
            "household_income": number (>= 0),
            "risk_profile": "CONSERVATIVE|MODERATE|AGGRESSIVE|VERY_AGGRESSIVE",
            "investment_strategies": ["GROWTH", "VALUE", "INCOME", "INDEX"],
            "investment_horizon_years": int (> 0),
            "existing_allocations": {"asset_class": percentage}
        }

    Response (200):
        AdvisoryRecommendation JSON with correlation_id header.

    Response (400):
        Validation error details.

    Response (504):
        Timeout with Retry-After header if SageMaker exceeds 500ms.
    """
    body = app.current_event.json_body

    # Validate client_id
    client_id = body.get("client_id")
    if not client_id or not isinstance(client_id, str):
        raise BadRequestError("'client_id' is required and must be a non-empty string")

    # Validate and parse customer profile
    profile = validate_customer_profile(body)

    # Generate recommendation
    service = _get_service()
    recommendation = service.get_recommendation(profile=profile, client_id=client_id)

    # Return response with correlation ID
    correlation_id = recommendation.recommendation_id
    return Response(
        status_code=200,
        content_type="application/json",
        body=json.dumps(recommendation.to_response_dict()),
        headers={"X-Correlation-Id": correlation_id},
    )


# --- Lambda Entry Point ---


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    """Lambda entry point for Advisory Agent service.

    Resolves HTTP API Gateway requests to route handlers.

    Args:
        event: API Gateway HTTP API event.
        context: Lambda execution context.

    Returns:
        API Gateway response dictionary.
    """
    return app.resolve(event, context)

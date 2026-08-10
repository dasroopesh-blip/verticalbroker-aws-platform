"""Data Quality Framework for VerticalBroker ETL pipelines.

Implements configurable data quality validation at Bronze-to-Silver and
Silver-to-Gold boundaries with severity-based handling:
- HIGH severity: halt pipeline, emit quality.failed event, prevent downstream propagation
- LOW severity: tag records, continue with quality_score metadata

Provides a data quality scorecard tracking completeness, accuracy, consistency,
and timeliness metrics per Gold dataset over a 90-day rolling window.

Requirements:
    18.1 - Execute data quality checks at Bronze-to-Silver and Silver-to-Gold boundaries
    18.2 - Validate schema conformance, null rates, referential integrity, range, freshness
    18.3 - HIGH severity: halt pipeline, emit quality.failed, prevent downstream propagation
    18.4 - LOW severity: log violation, tag records, continue with quality_score metadata
    18.5 - Maintain data quality scorecard per Gold dataset
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, Tuple
from uuid import uuid4

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StructType



# ---------------------------------------------------------------------------
# Enums and Configuration Classes
# ---------------------------------------------------------------------------


class Severity(Enum):
    """Data quality rule severity levels."""

    HIGH = "HIGH"
    LOW = "LOW"


class RuleType(Enum):
    """Types of data quality rules."""

    SCHEMA_CONFORMANCE = "schema_conformance"
    NULL_RATE = "null_rate"
    RANGE_VALIDATION = "range_validation"
    REFERENTIAL_INTEGRITY = "referential_integrity"
    FRESHNESS_SLA = "freshness_sla"


@dataclass
class QualityRuleConfig:
    """Configuration for a single data quality rule.

    Attributes:
        rule_type: Type of quality check to perform.
        column: Target column name (if applicable).
        severity: Default severity if the rule fails.
        params: Rule-specific parameters (thresholds, ranges, etc.).
    """

    rule_type: RuleType
    column: Optional[str] = None
    severity: Severity = Severity.LOW
    params: Dict[str, Any] = field(default_factory=dict)



@dataclass
class QualityRuleResult:
    """Result of evaluating a single quality rule.

    Attributes:
        rule_type: Which rule was evaluated.
        passed: Whether the rule passed.
        severity: Severity level if failed (None if passed).
        metric_value: The measured metric (e.g., null rate percentage).
        threshold: The configured threshold that was checked against.
        column: Column the rule applies to (if applicable).
        message: Human-readable description of result.
        failed_record_count: Number of records that violated the rule.
    """

    rule_type: RuleType
    passed: bool
    severity: Optional[Severity] = None
    metric_value: float = 0.0
    threshold: float = 0.0
    column: Optional[str] = None
    message: str = ""
    failed_record_count: int = 0


@dataclass
class QualityAssessment:
    """Aggregate assessment of all quality rules for a dataset.

    Attributes:
        dataset_name: Name of the dataset being assessed.
        timestamp: When the assessment was performed.
        overall_score: Composite quality score (0-100).
        passed: Whether the dataset passes overall quality gates.
        halt_pipeline: Whether the pipeline should be halted.
        rule_results: Individual results for each rule evaluated.
        high_severity_failures: Count of HIGH severity failures.
        low_severity_failures: Count of LOW severity failures.
    """

    dataset_name: str
    timestamp: str = ""
    overall_score: float = 100.0
    passed: bool = True
    halt_pipeline: bool = False
    rule_results: List[QualityRuleResult] = field(default_factory=list)
    high_severity_failures: int = 0
    low_severity_failures: int = 0

    def __post_init__(self):
        if not self.timestamp:
            self.timestamp = datetime.now(timezone.utc).isoformat()



@dataclass
class QualityScorecard:
    """Data quality scorecard tracking metrics over time per Gold dataset.

    Maintains 90-day rolling history of completeness, accuracy,
    consistency, and timeliness metrics.

    Attributes:
        dataset_name: Name of the Gold dataset.
        completeness: Percentage of non-null required fields (0-100).
        accuracy: Percentage of records within valid ranges (0-100).
        consistency: Percentage of referentially consistent records (0-100).
        timeliness: Percentage meeting freshness SLA (0-100).
        overall_score: Weighted composite score (0-100).
        measurement_timestamp: When this scorecard was computed.
        history_days: Number of days of history maintained.
    """

    dataset_name: str
    completeness: float = 100.0
    accuracy: float = 100.0
    consistency: float = 100.0
    timeliness: float = 100.0
    overall_score: float = 100.0
    measurement_timestamp: str = ""
    history_days: int = 90

    def __post_init__(self):
        if not self.measurement_timestamp:
            self.measurement_timestamp = datetime.now(timezone.utc).isoformat()
        self.overall_score = self.compute_overall_score()

    def compute_overall_score(self) -> float:
        """Compute weighted overall quality score (0-100).

        Weights: completeness=30%, accuracy=30%, consistency=25%, timeliness=15%
        """
        score = (
            self.completeness * 0.30
            + self.accuracy * 0.30
            + self.consistency * 0.25
            + self.timeliness * 0.15
        )
        return round(max(0.0, min(100.0, score)), 2)



# ---------------------------------------------------------------------------
# Data Quality Engine
# ---------------------------------------------------------------------------


class DataQualityEngine:
    """Configurable data quality validation engine for ETL pipelines.

    Executes quality rules at Bronze-to-Silver and Silver-to-Gold boundaries
    with severity-based handling. HIGH severity failures halt the pipeline and
    emit quality.failed events. LOW severity failures tag records and continue
    processing with quality_score metadata.

    Default thresholds:
        - Null rate: 5% (configurable per column)
        - Freshness SLA: 24 hours
        - Referential integrity: 1% violation triggers HIGH
        - Range violations: 1% triggers HIGH

    Args:
        spark: Active SparkSession instance.
        dataset_name: Name of dataset being validated.
        rules: List of quality rule configurations.
        null_rate_threshold: Default null rate threshold (fraction, e.g., 0.05 = 5%).
        freshness_sla_hours: Default freshness SLA in hours.
        event_emitter: Optional callable to emit EventBridge events.
    """

    # Default configuration constants
    DEFAULT_NULL_RATE_THRESHOLD = 0.05  # 5%
    DEFAULT_FRESHNESS_SLA_HOURS = 24
    HIGH_NULL_MULTIPLIER = 3.0  # >3x threshold = HIGH severity
    HIGH_REFERENTIAL_INTEGRITY_THRESHOLD = 0.01  # >1% violations = HIGH
    HIGH_RANGE_VIOLATION_THRESHOLD = 0.01  # >1% violations = HIGH
    FRESHNESS_HIGH_MULTIPLIER = 2.0  # >2x SLA missed = HIGH
    SCORE_DEGRADED_THRESHOLD = 80.0  # Alert when below this

    def __init__(
        self,
        spark: SparkSession,
        dataset_name: str,
        rules: Optional[List[QualityRuleConfig]] = None,
        null_rate_threshold: float = DEFAULT_NULL_RATE_THRESHOLD,
        freshness_sla_hours: int = DEFAULT_FRESHNESS_SLA_HOURS,
        event_emitter: Optional[Callable[[Dict[str, Any]], None]] = None,
    ):
        self.spark = spark
        self.dataset_name = dataset_name
        self.rules = rules or []
        self.null_rate_threshold = null_rate_threshold
        self.freshness_sla_hours = freshness_sla_hours
        self.event_emitter = event_emitter
        self._scorecard_history: List[QualityScorecard] = []


    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def evaluate(self, df: DataFrame) -> QualityAssessment:
        """Evaluate all configured quality rules against the DataFrame.

        Executes each rule in sequence, collecting results and determining
        the overall assessment. If any rule evaluation fails due to an
        infrastructure error, it is treated as HIGH severity and the
        pipeline is halted.

        Args:
            df: PySpark DataFrame to validate.

        Returns:
            QualityAssessment with overall score and per-rule results.
        """
        assessment = QualityAssessment(dataset_name=self.dataset_name)
        total_records = df.count()

        if total_records == 0:
            assessment.passed = True
            assessment.overall_score = 100.0
            return assessment

        for rule in self.rules:
            try:
                result = self._evaluate_rule(rule, df, total_records)
            except Exception as e:
                # Infrastructure error during rule evaluation: treat as HIGH
                result = QualityRuleResult(
                    rule_type=rule.rule_type,
                    passed=False,
                    severity=Severity.HIGH,
                    column=rule.column,
                    message=(
                        f"Infrastructure error evaluating rule "
                        f"{rule.rule_type.value}: {str(e)}"
                    ),
                )

            assessment.rule_results.append(result)

            if not result.passed:
                if result.severity == Severity.HIGH:
                    assessment.high_severity_failures += 1
                else:
                    assessment.low_severity_failures += 1

        # Determine overall assessment
        assessment.halt_pipeline = assessment.high_severity_failures > 0
        assessment.passed = not assessment.halt_pipeline
        assessment.overall_score = self._compute_quality_score(
            assessment.rule_results, total_records
        )

        # Emit events based on assessment
        if assessment.halt_pipeline:
            self._emit_quality_failed_event(assessment)
        if assessment.overall_score < self.SCORE_DEGRADED_THRESHOLD:
            self._emit_score_degraded_alert(assessment)

        return assessment


    def apply_quality_tags(
        self, df: DataFrame, assessment: QualityAssessment
    ) -> DataFrame:
        """Tag DataFrame records with quality score metadata.

        For LOW severity failures, adds quality_score column and
        quality_flags column to enable downstream consumers to
        filter or weight records based on quality.

        Args:
            df: Original DataFrame.
            assessment: QualityAssessment from evaluate().

        Returns:
            DataFrame with quality_score and quality_flags columns added.
        """
        quality_score = assessment.overall_score

        # Build list of quality flag descriptions
        flags = [
            r.message
            for r in assessment.rule_results
            if not r.passed and r.severity == Severity.LOW
        ]
        flags_json = json.dumps(flags)

        tagged_df = df.withColumn(
            "quality_score", F.lit(quality_score).cast("double")
        ).withColumn("quality_flags", F.lit(flags_json).cast("string"))

        return tagged_df

    def compute_scorecard(self, df: DataFrame) -> QualityScorecard:
        """Compute the data quality scorecard for a Gold dataset.

        Measures completeness, accuracy, consistency, and timeliness
        and stores the result in the 90-day rolling history.

        Args:
            df: Gold dataset DataFrame to assess.

        Returns:
            QualityScorecard with current metrics.
        """
        total_records = df.count()
        if total_records == 0:
            return QualityScorecard(dataset_name=self.dataset_name)

        completeness = self._measure_completeness(df, total_records)
        accuracy = self._measure_accuracy(df, total_records)
        consistency = self._measure_consistency(df, total_records)
        timeliness = self._measure_timeliness(df, total_records)

        scorecard = QualityScorecard(
            dataset_name=self.dataset_name,
            completeness=completeness,
            accuracy=accuracy,
            consistency=consistency,
            timeliness=timeliness,
        )

        # Maintain 90-day rolling history
        self._scorecard_history.append(scorecard)
        cutoff = datetime.now(timezone.utc) - timedelta(days=90)
        self._scorecard_history = [
            s
            for s in self._scorecard_history
            if datetime.fromisoformat(s.measurement_timestamp) >= cutoff
        ]

        # Check for score degradation
        if scorecard.overall_score < self.SCORE_DEGRADED_THRESHOLD:
            self._emit_score_degraded_alert(
                QualityAssessment(
                    dataset_name=self.dataset_name,
                    overall_score=scorecard.overall_score,
                )
            )

        return scorecard


    def get_scorecard_history(self) -> List[QualityScorecard]:
        """Return the 90-day scorecard history for this dataset.

        Returns:
            List of QualityScorecard entries within the 90-day window.
        """
        return list(self._scorecard_history)

    # ------------------------------------------------------------------
    # Rule Evaluation Methods
    # ------------------------------------------------------------------

    def _evaluate_rule(
        self, rule: QualityRuleConfig, df: DataFrame, total_records: int
    ) -> QualityRuleResult:
        """Dispatch rule evaluation to the appropriate handler.

        Args:
            rule: Rule configuration to evaluate.
            df: DataFrame to validate.
            total_records: Total record count in the DataFrame.

        Returns:
            QualityRuleResult for this rule.
        """
        evaluators = {
            RuleType.SCHEMA_CONFORMANCE: self._evaluate_schema_conformance,
            RuleType.NULL_RATE: self._evaluate_null_rate,
            RuleType.RANGE_VALIDATION: self._evaluate_range_validation,
            RuleType.REFERENTIAL_INTEGRITY: self._evaluate_referential_integrity,
            RuleType.FRESHNESS_SLA: self._evaluate_freshness_sla,
        }

        evaluator = evaluators.get(rule.rule_type)
        if evaluator is None:
            return QualityRuleResult(
                rule_type=rule.rule_type,
                passed=False,
                severity=Severity.HIGH,
                message=f"Unknown rule type: {rule.rule_type.value}",
            )

        return evaluator(rule, df, total_records)


    def _evaluate_schema_conformance(
        self, rule: QualityRuleConfig, df: DataFrame, total_records: int
    ) -> QualityRuleResult:
        """Validate that DataFrame conforms to expected schema.

        Schema failures are always HIGH severity as they indicate
        structural data corruption.

        Args:
            rule: Rule config with optional params['expected_schema'] as StructType.
            df: DataFrame to validate.
            total_records: Total record count.

        Returns:
            QualityRuleResult indicating schema conformance.
        """
        expected_schema: Optional[StructType] = rule.params.get("expected_schema")

        if expected_schema is None:
            # If no schema provided, check that no columns are entirely null
            # (indicating missing/corrupt data)
            all_null_cols = []
            for col_name in df.columns:
                non_null_count = df.filter(F.col(col_name).isNotNull()).count()
                if non_null_count == 0:
                    all_null_cols.append(col_name)

            if all_null_cols:
                return QualityRuleResult(
                    rule_type=RuleType.SCHEMA_CONFORMANCE,
                    passed=False,
                    severity=Severity.HIGH,
                    message=(
                        f"Schema failure: columns entirely null: "
                        f"{', '.join(all_null_cols)}"
                    ),
                    failed_record_count=total_records,
                )
            return QualityRuleResult(
                rule_type=RuleType.SCHEMA_CONFORMANCE,
                passed=True,
                message="Schema conformance check passed (no entirely null columns)",
            )

        # Validate against expected schema
        actual_fields = {f.name: f.dataType for f in df.schema.fields}
        expected_fields = {f.name: f.dataType for f in expected_schema.fields}

        missing_cols = set(expected_fields.keys()) - set(actual_fields.keys())
        type_mismatches = []

        for col_name, expected_type in expected_fields.items():
            if col_name in actual_fields and actual_fields[col_name] != expected_type:
                type_mismatches.append(
                    f"{col_name}: expected {expected_type}, got {actual_fields[col_name]}"
                )

        if missing_cols or type_mismatches:
            issues = []
            if missing_cols:
                issues.append(f"missing columns: {', '.join(missing_cols)}")
            if type_mismatches:
                issues.append(f"type mismatches: {'; '.join(type_mismatches)}")

            return QualityRuleResult(
                rule_type=RuleType.SCHEMA_CONFORMANCE,
                passed=False,
                severity=Severity.HIGH,
                message=f"Schema failure: {'; '.join(issues)}",
                failed_record_count=total_records,
            )

        return QualityRuleResult(
            rule_type=RuleType.SCHEMA_CONFORMANCE,
            passed=True,
            message="Schema conformance validated against expected schema",
        )


    def _evaluate_null_rate(
        self, rule: QualityRuleConfig, df: DataFrame, total_records: int
    ) -> QualityRuleResult:
        """Check null rate for a specific column against threshold.

        Severity escalation:
            - Null rate > threshold but < 3x threshold: LOW severity
            - Null rate > 3x threshold: HIGH severity

        Args:
            rule: Rule config with column name and optional params['threshold'].
            df: DataFrame to validate.
            total_records: Total record count.

        Returns:
            QualityRuleResult with null rate measurement.
        """
        column = rule.column
        if column is None or column not in df.columns:
            return QualityRuleResult(
                rule_type=RuleType.NULL_RATE,
                passed=True,
                column=column,
                message=f"Column '{column}' not found, skipping null check",
            )

        threshold = rule.params.get("threshold", self.null_rate_threshold)
        null_count = df.filter(F.col(column).isNull()).count()
        null_rate = null_count / total_records if total_records > 0 else 0.0

        if null_rate <= threshold:
            return QualityRuleResult(
                rule_type=RuleType.NULL_RATE,
                passed=True,
                metric_value=null_rate,
                threshold=threshold,
                column=column,
                message=(
                    f"Null rate for '{column}': {null_rate:.4f} "
                    f"(threshold: {threshold})"
                ),
            )

        # Determine severity based on how much threshold is exceeded
        if null_rate > threshold * self.HIGH_NULL_MULTIPLIER:
            severity = Severity.HIGH
        else:
            severity = Severity.LOW

        return QualityRuleResult(
            rule_type=RuleType.NULL_RATE,
            passed=False,
            severity=severity,
            metric_value=null_rate,
            threshold=threshold,
            column=column,
            message=(
                f"Null rate for '{column}': {null_rate:.4f} exceeds "
                f"threshold {threshold} (severity: {severity.value})"
            ),
            failed_record_count=null_count,
        )


    def _evaluate_range_validation(
        self, rule: QualityRuleConfig, df: DataFrame, total_records: int
    ) -> QualityRuleResult:
        """Validate that column values fall within expected range.

        Severity escalation:
            - Range violations < 1%: LOW severity
            - Range violations >= 1%: HIGH severity

        Args:
            rule: Rule config with params['min_value'] and/or params['max_value'].
            df: DataFrame to validate.
            total_records: Total record count.

        Returns:
            QualityRuleResult with violation rate measurement.
        """
        column = rule.column
        if column is None or column not in df.columns:
            return QualityRuleResult(
                rule_type=RuleType.RANGE_VALIDATION,
                passed=True,
                column=column,
                message=f"Column '{column}' not found, skipping range check",
            )

        min_value = rule.params.get("min_value")
        max_value = rule.params.get("max_value")

        if min_value is None and max_value is None:
            return QualityRuleResult(
                rule_type=RuleType.RANGE_VALIDATION,
                passed=True,
                column=column,
                message=f"No range bounds configured for '{column}'",
            )

        # Build violation filter
        conditions = []
        if min_value is not None:
            conditions.append(F.col(column) < min_value)
        if max_value is not None:
            conditions.append(F.col(column) > max_value)

        # Combine conditions with OR (any violation counts)
        violation_filter = conditions[0]
        for cond in conditions[1:]:
            violation_filter = violation_filter | cond

        # Only check non-null records for range validity
        non_null_df = df.filter(F.col(column).isNotNull())
        non_null_count = non_null_df.count()

        if non_null_count == 0:
            return QualityRuleResult(
                rule_type=RuleType.RANGE_VALIDATION,
                passed=True,
                column=column,
                message=f"No non-null values to validate range for '{column}'",
            )

        violation_count = non_null_df.filter(violation_filter).count()
        violation_rate = violation_count / non_null_count

        if violation_rate == 0.0:
            return QualityRuleResult(
                rule_type=RuleType.RANGE_VALIDATION,
                passed=True,
                metric_value=violation_rate,
                column=column,
                message=f"Range validation passed for '{column}'",
            )

        # Determine severity
        if violation_rate >= self.HIGH_RANGE_VIOLATION_THRESHOLD:
            severity = Severity.HIGH
        else:
            severity = Severity.LOW

        return QualityRuleResult(
            rule_type=RuleType.RANGE_VALIDATION,
            passed=False,
            severity=severity,
            metric_value=violation_rate,
            threshold=self.HIGH_RANGE_VIOLATION_THRESHOLD,
            column=column,
            message=(
                f"Range violations for '{column}': {violation_rate:.4f} "
                f"({violation_count}/{non_null_count} records out of range "
                f"[{min_value}, {max_value}])"
            ),
            failed_record_count=violation_count,
        )


    def _evaluate_referential_integrity(
        self, rule: QualityRuleConfig, df: DataFrame, total_records: int
    ) -> QualityRuleResult:
        """Check referential integrity between datasets.

        Validates that foreign key values in the current DataFrame
        exist in a reference DataFrame.

        Severity escalation:
            - Violation rate > 1%: HIGH severity
            - Violation rate <= 1%: LOW severity

        Args:
            rule: Rule config with params['reference_df'] (DataFrame),
                  params['reference_column'] (str for join key in reference).
            df: DataFrame to validate.
            total_records: Total record count.

        Returns:
            QualityRuleResult with integrity violation measurement.
        """
        column = rule.column
        reference_df: Optional[DataFrame] = rule.params.get("reference_df")
        reference_column: Optional[str] = rule.params.get("reference_column")

        if column is None or column not in df.columns:
            return QualityRuleResult(
                rule_type=RuleType.REFERENTIAL_INTEGRITY,
                passed=True,
                column=column,
                message=(
                    f"Column '{column}' not found, "
                    f"skipping referential integrity check"
                ),
            )

        if reference_df is None:
            return QualityRuleResult(
                rule_type=RuleType.REFERENTIAL_INTEGRITY,
                passed=True,
                column=column,
                message="No reference DataFrame provided, skipping integrity check",
            )

        ref_col = reference_column or column

        # Get distinct values from both sides
        source_values = df.select(column).filter(F.col(column).isNotNull()).distinct()
        reference_values = reference_df.select(
            F.col(ref_col).alias(column)
        ).distinct()

        # Find orphan records (in source but not in reference)
        orphans = source_values.subtract(reference_values)
        orphan_count = orphans.count()

        # Count all records with orphan FK values
        if orphan_count > 0:
            orphan_values = [row[0] for row in orphans.collect()]
            violation_count = df.filter(F.col(column).isin(orphan_values)).count()
        else:
            violation_count = 0

        violation_rate = violation_count / total_records if total_records > 0 else 0.0

        if violation_count == 0:
            return QualityRuleResult(
                rule_type=RuleType.REFERENTIAL_INTEGRITY,
                passed=True,
                metric_value=0.0,
                column=column,
                message=f"Referential integrity passed for '{column}'",
            )

        # Determine severity
        if violation_rate > self.HIGH_REFERENTIAL_INTEGRITY_THRESHOLD:
            severity = Severity.HIGH
        else:
            severity = Severity.LOW

        return QualityRuleResult(
            rule_type=RuleType.REFERENTIAL_INTEGRITY,
            passed=False,
            severity=severity,
            metric_value=violation_rate,
            threshold=self.HIGH_REFERENTIAL_INTEGRITY_THRESHOLD,
            column=column,
            message=(
                f"Referential integrity violations for '{column}': "
                f"{violation_rate:.4f} ({violation_count}/{total_records} records "
                f"with {orphan_count} orphan distinct values)"
            ),
            failed_record_count=violation_count,
        )


    def _evaluate_freshness_sla(
        self, rule: QualityRuleConfig, df: DataFrame, total_records: int
    ) -> QualityRuleResult:
        """Check that data meets freshness SLA requirements.

        Validates that the most recent timestamp in the dataset is
        within the configured SLA window (default: 24 hours).

        Severity escalation:
            - Freshness missed by < 2x SLA: LOW severity
            - Freshness missed by >= 2x SLA: HIGH severity

        Args:
            rule: Rule config with optional params['sla_hours'],
                  params['timestamp_column'].
            df: DataFrame to validate.
            total_records: Total record count.

        Returns:
            QualityRuleResult with freshness measurement.
        """
        sla_hours = rule.params.get("sla_hours", self.freshness_sla_hours)
        timestamp_column = rule.params.get("timestamp_column", "source_timestamp")

        if timestamp_column not in df.columns:
            return QualityRuleResult(
                rule_type=RuleType.FRESHNESS_SLA,
                passed=True,
                column=timestamp_column,
                message=(
                    f"Timestamp column '{timestamp_column}' not found, "
                    f"skipping freshness check"
                ),
            )

        # Get the most recent timestamp in the dataset
        max_ts_row = df.agg(F.max(F.col(timestamp_column)).alias("max_ts")).collect()
        max_ts = max_ts_row[0]["max_ts"] if max_ts_row else None

        if max_ts is None:
            return QualityRuleResult(
                rule_type=RuleType.FRESHNESS_SLA,
                passed=False,
                severity=Severity.HIGH,
                column=timestamp_column,
                message=(
                    f"No valid timestamps found in '{timestamp_column}', "
                    f"cannot verify freshness"
                ),
                failed_record_count=total_records,
            )

        # Calculate staleness
        now = datetime.now(timezone.utc)
        if isinstance(max_ts, str):
            max_ts = datetime.fromisoformat(max_ts)
        elif not hasattr(max_ts, "tzinfo"):
            # If datetime is naive, assume UTC
            max_ts = max_ts.replace(tzinfo=timezone.utc)
        elif max_ts.tzinfo is None:
            max_ts = max_ts.replace(tzinfo=timezone.utc)

        staleness_hours = (now - max_ts).total_seconds() / 3600.0
        sla_threshold = float(sla_hours)

        if staleness_hours <= sla_threshold:
            return QualityRuleResult(
                rule_type=RuleType.FRESHNESS_SLA,
                passed=True,
                metric_value=staleness_hours,
                threshold=sla_threshold,
                column=timestamp_column,
                message=(
                    f"Freshness OK: data is {staleness_hours:.2f}h old "
                    f"(SLA: {sla_threshold}h)"
                ),
            )

        # Determine severity based on how much SLA is missed
        if staleness_hours >= sla_threshold * self.FRESHNESS_HIGH_MULTIPLIER:
            severity = Severity.HIGH
        else:
            severity = Severity.LOW

        return QualityRuleResult(
            rule_type=RuleType.FRESHNESS_SLA,
            passed=False,
            severity=severity,
            metric_value=staleness_hours,
            threshold=sla_threshold,
            column=timestamp_column,
            message=(
                f"Freshness SLA violated: data is {staleness_hours:.2f}h old "
                f"(SLA: {sla_threshold}h, severity: {severity.value})"
            ),
            failed_record_count=total_records,
        )


    # ------------------------------------------------------------------
    # Quality Score Calculation
    # ------------------------------------------------------------------

    def _compute_quality_score(
        self, results: List[QualityRuleResult], total_records: int
    ) -> float:
        """Compute overall quality score (0-100) from rule results.

        The score is calculated as a weighted combination of rule pass rates:
        - Schema conformance: 30% weight (binary pass/fail)
        - Null rate compliance: 25% weight (inverse of null rate deviation)
        - Range validity: 20% weight (inverse of violation rate)
        - Referential integrity: 15% weight (inverse of violation rate)
        - Freshness: 10% weight (binary SLA met/missed)

        Args:
            results: List of individual rule results.
            total_records: Total records in the dataset.

        Returns:
            Quality score from 0 to 100.
        """
        if not results:
            return 100.0

        weights = {
            RuleType.SCHEMA_CONFORMANCE: 30.0,
            RuleType.NULL_RATE: 25.0,
            RuleType.RANGE_VALIDATION: 20.0,
            RuleType.REFERENTIAL_INTEGRITY: 15.0,
            RuleType.FRESHNESS_SLA: 10.0,
        }

        # Group results by rule type and compute per-type scores
        type_scores: Dict[RuleType, List[float]] = {}
        for result in results:
            if result.rule_type not in type_scores:
                type_scores[result.rule_type] = []

            if result.passed:
                type_scores[result.rule_type].append(100.0)
            else:
                # Score based on severity and violation rate
                if result.severity == Severity.HIGH:
                    type_scores[result.rule_type].append(0.0)
                else:
                    # LOW severity: partial score based on metric
                    if total_records > 0 and result.failed_record_count > 0:
                        pass_rate = 1.0 - (
                            result.failed_record_count / total_records
                        )
                        type_scores[result.rule_type].append(
                            max(0.0, pass_rate * 100.0)
                        )
                    else:
                        type_scores[result.rule_type].append(50.0)

        # Compute weighted score
        weighted_sum = 0.0
        total_weight = 0.0

        for rule_type, scores in type_scores.items():
            weight = weights.get(rule_type, 10.0)
            avg_score = sum(scores) / len(scores) if scores else 100.0
            weighted_sum += avg_score * weight
            total_weight += weight

        # For rule types not evaluated, assume 100% (no penalty)
        if total_weight == 0.0:
            return 100.0

        final_score = weighted_sum / total_weight
        return round(max(0.0, min(100.0, final_score)), 2)


    # ------------------------------------------------------------------
    # Scorecard Measurement Methods
    # ------------------------------------------------------------------

    def _measure_completeness(self, df: DataFrame, total_records: int) -> float:
        """Measure data completeness (non-null rate across all columns).

        Returns:
            Completeness percentage (0-100).
        """
        total_cells = total_records * len(df.columns)
        if total_cells == 0:
            return 100.0

        null_counts = df.select(
            [F.sum(F.when(F.col(c).isNull(), 1).otherwise(0)).alias(c) for c in df.columns]
        ).collect()[0]

        total_nulls = sum(null_counts[c] or 0 for c in df.columns)
        completeness = (1.0 - (total_nulls / total_cells)) * 100.0
        return round(max(0.0, min(100.0, completeness)), 2)

    def _measure_accuracy(self, df: DataFrame, total_records: int) -> float:
        """Measure data accuracy (records within configured valid ranges).

        Uses range validation rules to determine accuracy. If no range
        rules are configured, returns 100%.

        Returns:
            Accuracy percentage (0-100).
        """
        range_rules = [r for r in self.rules if r.rule_type == RuleType.RANGE_VALIDATION]
        if not range_rules:
            return 100.0

        total_violations = 0
        total_checked = 0

        for rule in range_rules:
            column = rule.column
            if column is None or column not in df.columns:
                continue

            min_value = rule.params.get("min_value")
            max_value = rule.params.get("max_value")
            if min_value is None and max_value is None:
                continue

            non_null_df = df.filter(F.col(column).isNotNull())
            non_null_count = non_null_df.count()
            total_checked += non_null_count

            conditions = []
            if min_value is not None:
                conditions.append(F.col(column) < min_value)
            if max_value is not None:
                conditions.append(F.col(column) > max_value)

            violation_filter = conditions[0]
            for cond in conditions[1:]:
                violation_filter = violation_filter | cond

            total_violations += non_null_df.filter(violation_filter).count()

        if total_checked == 0:
            return 100.0

        accuracy = (1.0 - (total_violations / total_checked)) * 100.0
        return round(max(0.0, min(100.0, accuracy)), 2)


    def _measure_consistency(self, df: DataFrame, total_records: int) -> float:
        """Measure data consistency (referential integrity compliance).

        Uses referential integrity rules to determine consistency. If no
        referential integrity rules are configured, returns 100%.

        Returns:
            Consistency percentage (0-100).
        """
        ri_rules = [
            r for r in self.rules if r.rule_type == RuleType.REFERENTIAL_INTEGRITY
        ]
        if not ri_rules:
            return 100.0

        total_violations = 0
        total_checked = 0

        for rule in ri_rules:
            column = rule.column
            reference_df = rule.params.get("reference_df")
            reference_column = rule.params.get("reference_column")

            if column is None or column not in df.columns or reference_df is None:
                continue

            ref_col = reference_column or column
            source_non_null = df.filter(F.col(column).isNotNull())
            source_count = source_non_null.count()
            total_checked += source_count

            source_values = source_non_null.select(column).distinct()
            reference_values = reference_df.select(
                F.col(ref_col).alias(column)
            ).distinct()

            orphans = source_values.subtract(reference_values)
            orphan_count = orphans.count()

            if orphan_count > 0:
                orphan_values = [row[0] for row in orphans.collect()]
                total_violations += (
                    source_non_null.filter(F.col(column).isin(orphan_values)).count()
                )

        if total_checked == 0:
            return 100.0

        consistency = (1.0 - (total_violations / total_checked)) * 100.0
        return round(max(0.0, min(100.0, consistency)), 2)

    def _measure_timeliness(self, df: DataFrame, total_records: int) -> float:
        """Measure data timeliness (freshness SLA compliance).

        Checks what percentage of records fall within the freshness SLA
        window. Uses freshness rules or defaults to the configured SLA.

        Returns:
            Timeliness percentage (0-100).
        """
        freshness_rules = [
            r for r in self.rules if r.rule_type == RuleType.FRESHNESS_SLA
        ]

        # Find timestamp column from rules or use default
        timestamp_column = "source_timestamp"
        sla_hours = self.freshness_sla_hours

        if freshness_rules:
            timestamp_column = freshness_rules[0].params.get(
                "timestamp_column", "source_timestamp"
            )
            sla_hours = freshness_rules[0].params.get(
                "sla_hours", self.freshness_sla_hours
            )

        if timestamp_column not in df.columns:
            return 100.0

        # Calculate what percentage of records are within SLA
        now = datetime.now(timezone.utc)
        sla_cutoff = now - timedelta(hours=sla_hours)

        records_with_ts = df.filter(F.col(timestamp_column).isNotNull())
        ts_count = records_with_ts.count()

        if ts_count == 0:
            return 100.0

        timely_count = records_with_ts.filter(
            F.col(timestamp_column) >= F.lit(sla_cutoff)
        ).count()

        timeliness = (timely_count / ts_count) * 100.0
        return round(max(0.0, min(100.0, timeliness)), 2)


    # ------------------------------------------------------------------
    # Event Emission
    # ------------------------------------------------------------------

    def _emit_quality_failed_event(self, assessment: QualityAssessment) -> None:
        """Emit quality.failed event to EventBridge.

        Emitted when HIGH severity failures are detected, causing
        pipeline halt and preventing downstream propagation.

        Args:
            assessment: The quality assessment with failure details.
        """
        event_detail = {
            "event_type": "quality.failed",
            "dataset_name": assessment.dataset_name,
            "timestamp": assessment.timestamp,
            "overall_score": assessment.overall_score,
            "high_severity_failures": assessment.high_severity_failures,
            "low_severity_failures": assessment.low_severity_failures,
            "failure_details": [
                {
                    "rule_type": r.rule_type.value,
                    "column": r.column,
                    "severity": r.severity.value if r.severity else None,
                    "metric_value": r.metric_value,
                    "threshold": r.threshold,
                    "message": r.message,
                    "failed_record_count": r.failed_record_count,
                }
                for r in assessment.rule_results
                if not r.passed and r.severity == Severity.HIGH
            ],
        }

        if self.event_emitter:
            self.event_emitter(event_detail)

    def _emit_score_degraded_alert(self, assessment: QualityAssessment) -> None:
        """Emit quality.score_degraded alert when score drops below 80.

        Args:
            assessment: The quality assessment with degraded score.
        """
        event_detail = {
            "event_type": "quality.score_degraded",
            "dataset_name": assessment.dataset_name,
            "timestamp": assessment.timestamp,
            "overall_score": assessment.overall_score,
            "threshold": self.SCORE_DEGRADED_THRESHOLD,
            "message": (
                f"Quality score for '{assessment.dataset_name}' dropped to "
                f"{assessment.overall_score} (below threshold "
                f"{self.SCORE_DEGRADED_THRESHOLD})"
            ),
        }

        if self.event_emitter:
            self.event_emitter(event_detail)



# ---------------------------------------------------------------------------
# Convenience Factory Functions
# ---------------------------------------------------------------------------


def create_default_rules(
    columns: List[str],
    null_threshold: float = DataQualityEngine.DEFAULT_NULL_RATE_THRESHOLD,
    freshness_sla_hours: int = DataQualityEngine.DEFAULT_FRESHNESS_SLA_HOURS,
    range_columns: Optional[Dict[str, Dict[str, float]]] = None,
    timestamp_column: str = "source_timestamp",
) -> List[QualityRuleConfig]:
    """Create a default set of quality rules for common validation patterns.

    Generates rules for:
    - Schema conformance (always included)
    - Null rate checks for all specified columns
    - Range validation for columns with configured bounds
    - Freshness SLA check

    Args:
        columns: List of column names to check for null rates.
        null_threshold: Default null rate threshold (fraction, 0.05 = 5%).
        freshness_sla_hours: Freshness SLA in hours (default 24).
        range_columns: Dict mapping column names to {"min_value": x, "max_value": y}.
        timestamp_column: Column name containing timestamps for freshness check.

    Returns:
        List of QualityRuleConfig for use with DataQualityEngine.
    """
    rules: List[QualityRuleConfig] = []

    # Schema conformance rule (always included)
    rules.append(
        QualityRuleConfig(
            rule_type=RuleType.SCHEMA_CONFORMANCE,
            severity=Severity.HIGH,
        )
    )

    # Null rate rules for each column
    for col in columns:
        rules.append(
            QualityRuleConfig(
                rule_type=RuleType.NULL_RATE,
                column=col,
                severity=Severity.LOW,
                params={"threshold": null_threshold},
            )
        )

    # Range validation rules
    if range_columns:
        for col, bounds in range_columns.items():
            rules.append(
                QualityRuleConfig(
                    rule_type=RuleType.RANGE_VALIDATION,
                    column=col,
                    severity=Severity.LOW,
                    params=bounds,
                )
            )

    # Freshness SLA rule
    rules.append(
        QualityRuleConfig(
            rule_type=RuleType.FRESHNESS_SLA,
            severity=Severity.LOW,
            params={
                "sla_hours": freshness_sla_hours,
                "timestamp_column": timestamp_column,
            },
        )
    )

    return rules


__all__ = [
    "DataQualityEngine",
    "QualityRuleConfig",
    "QualityRuleResult",
    "QualityAssessment",
    "QualityScorecard",
    "RuleType",
    "Severity",
    "create_default_rules",
]

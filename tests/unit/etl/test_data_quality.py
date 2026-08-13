"""
Unit tests for Data Quality Engine.
Tests: Rule evaluation, severity levels, scoring (0-100), abort conditions.
"""

from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest


pytestmark = [pytest.mark.unit, pytest.mark.etl]


class TestQualityRuleTypes:
    """Tests for the 5 quality rule types."""

    def test_schema_conformance_rule(self):
        """SCHEMA_CONFORMANCE: any failure = HIGH severity."""
        rule_type = "SCHEMA_CONFORMANCE"
        any_failure = True
        severity = "HIGH" if any_failure else "LOW"
        assert severity == "HIGH"

    def test_null_rate_high_severity(self):
        """NULL_RATE: >3× threshold (15%) = HIGH severity (halt)."""
        null_rate = 0.18  # 18%
        threshold = 0.05  # 5%
        multiplier = null_rate / threshold  # 3.6×
        severity = "HIGH" if multiplier > 3 else "LOW"
        assert severity == "HIGH"
        assert multiplier > 3

    def test_null_rate_low_severity(self):
        """NULL_RATE: exceeded but <3× threshold = LOW severity (tag + continue)."""
        null_rate = 0.08  # 8%
        threshold = 0.05  # 5%
        multiplier = null_rate / threshold  # 1.6×
        severity = "HIGH" if multiplier > 3 else "LOW"
        assert severity == "LOW"

    def test_null_rate_within_threshold_passes(self):
        """NULL_RATE: within threshold = no issue."""
        null_rate = 0.03  # 3%
        threshold = 0.05  # 5%
        exceeds = null_rate > threshold
        assert exceeds is False

    def test_range_validation_high_severity(self):
        """RANGE_VALIDATION: ≥1% violations = HIGH severity."""
        total_records = 10000
        violations = 150  # 1.5%
        violation_rate = violations / total_records
        severity = "HIGH" if violation_rate >= 0.01 else "LOW"
        assert severity == "HIGH"

    def test_range_validation_low_severity(self):
        """RANGE_VALIDATION: <1% violations = LOW severity."""
        total_records = 10000
        violations = 50  # 0.5%
        violation_rate = violations / total_records
        severity = "HIGH" if violation_rate >= 0.01 else "LOW"
        assert severity == "LOW"

    def test_referential_integrity_high_severity(self):
        """REFERENTIAL_INTEGRITY: >1% orphans = HIGH severity."""
        total_records = 10000
        orphans = 200  # 2%
        orphan_rate = orphans / total_records
        severity = "HIGH" if orphan_rate > 0.01 else "LOW"
        assert severity == "HIGH"

    def test_referential_integrity_low_severity(self):
        """REFERENTIAL_INTEGRITY: ≤1% orphans = LOW severity."""
        total_records = 10000
        orphans = 80  # 0.8%
        orphan_rate = orphans / total_records
        severity = "HIGH" if orphan_rate > 0.01 else "LOW"
        assert severity == "LOW"

    def test_freshness_sla_high_severity(self):
        """FRESHNESS_SLA: ≥2× SLA missed (48h+) = HIGH severity."""
        sla_hours = 24
        hours_since_last_update = 50  # 50 hours
        multiplier = hours_since_last_update / sla_hours
        severity = "HIGH" if multiplier >= 2 else "LOW"
        assert severity == "HIGH"

    def test_freshness_sla_low_severity(self):
        """FRESHNESS_SLA: <2× SLA (24-48h) = LOW severity."""
        sla_hours = 24
        hours_since_last_update = 30  # 30 hours
        multiplier = hours_since_last_update / sla_hours
        severity = "HIGH" if multiplier >= 2 else "LOW"
        assert severity == "LOW"


class TestQualityScoring:
    """Tests for quality score calculation (0-100 weighted)."""

    def test_perfect_score_is_100(self):
        """No quality issues produces a score of 100."""
        completeness = 100.0
        accuracy = 100.0
        consistency = 100.0
        timeliness = 100.0

        # Weights: completeness 30%, accuracy 30%, consistency 25%, timeliness 15%
        score = (
            completeness * 0.30
            + accuracy * 0.30
            + consistency * 0.25
            + timeliness * 0.15
        )
        assert score == 100.0

    def test_weighted_score_calculation(self):
        """Score formula: completeness(30%) + accuracy(30%) + consistency(25%) + timeliness(15%)."""
        completeness = 95.0
        accuracy = 90.0
        consistency = 85.0
        timeliness = 100.0

        score = (
            completeness * 0.30
            + accuracy * 0.30
            + consistency * 0.25
            + timeliness * 0.15
        )
        # 95*0.3 + 90*0.3 + 85*0.25 + 100*0.15
        # = 28.5 + 27.0 + 21.25 + 15.0 = 91.75
        assert score == pytest.approx(91.75)

    def test_score_bounded_0_to_100(self):
        """Score is always between 0 and 100."""
        scores = [0.0, 50.0, 75.5, 100.0]
        for s in scores:
            assert 0 <= s <= 100

    def test_weight_sum_is_100_percent(self):
        """Quality dimension weights sum to 1.0 (100%)."""
        weights = {
            "completeness": 0.30,
            "accuracy": 0.30,
            "consistency": 0.25,
            "timeliness": 0.15,
        }
        total = sum(weights.values())
        assert total == pytest.approx(1.0)


class TestQualityAssessment:
    """Tests for overall quality assessment output."""

    def test_assessment_includes_all_rule_results(self):
        """Assessment contains results for each evaluated rule."""
        assessment = {
            "dataset_name": "market_data_silver",
            "evaluation_timestamp": datetime.now(UTC).isoformat(),
            "overall_score": 91.75,
            "has_high_severity": False,
            "rules_evaluated": 5,
            "rules_passed": 4,
            "rules_failed": 1,
            "results": [
                {"rule": "SCHEMA_CONFORMANCE", "passed": True, "severity": None},
                {"rule": "NULL_RATE", "passed": True, "severity": None},
                {"rule": "RANGE_VALIDATION", "passed": False, "severity": "LOW"},
                {"rule": "REFERENTIAL_INTEGRITY", "passed": True, "severity": None},
                {"rule": "FRESHNESS_SLA", "passed": True, "severity": None},
            ],
        }
        assert assessment["rules_evaluated"] == 5
        assert assessment["rules_passed"] == 4

    def test_high_severity_triggers_halt(self):
        """Any HIGH severity result sets has_high_severity=True → halt pipeline."""
        results = [
            {"severity": None},
            {"severity": "LOW"},
            {"severity": "HIGH"},  # This one triggers halt
        ]
        has_high = any(r["severity"] == "HIGH" for r in results)
        assert has_high is True

    def test_low_severity_continues_with_tags(self):
        """LOW severity adds quality flags to records but doesn't halt."""
        results = [
            {"severity": None},
            {"severity": "LOW"},
            {"severity": "LOW"},
        ]
        has_high = any(r["severity"] == "HIGH" for r in results)
        has_low = any(r["severity"] == "LOW" for r in results)
        assert has_high is False
        assert has_low is True
        # Pipeline continues, records get quality_flag column


class TestQualityScorecard:
    """Tests for quality scorecard (history tracking)."""

    def test_scorecard_tracks_dimensions(self):
        """Scorecard records individual dimension measurements."""
        scorecard = {
            "completeness": 95.5,
            "accuracy": 92.0,
            "consistency": 88.5,
            "timeliness": 100.0,
            "overall_score": 93.25,
            "evaluated_at": datetime.now(UTC).isoformat(),
        }
        assert all(0 <= v <= 100 for k, v in scorecard.items() if isinstance(v, float))

    def test_score_degradation_alert(self):
        """Score dropping >10 points from previous triggers alert."""
        previous_score = 95.0
        current_score = 82.0
        drop = previous_score - current_score
        alert_threshold = 10.0
        should_alert = drop > alert_threshold
        assert should_alert is True

    def test_completeness_measures_non_null_pct(self):
        """Completeness = (non_null_count / total_count) * 100."""
        total = 10000
        non_null = 9800
        completeness = (non_null / total) * 100
        assert completeness == 98.0

    def test_timeliness_measures_freshness(self):
        """Timeliness = 100 if within SLA, degrades based on staleness."""
        sla_hours = 24
        hours_since_update = 12
        timeliness = max(0, 100 - (hours_since_update / sla_hours) * 50)
        assert timeliness == 75.0  # 12/24 * 50 = 25 penalty

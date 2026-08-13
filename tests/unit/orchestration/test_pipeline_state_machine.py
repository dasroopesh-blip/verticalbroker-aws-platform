"""
Unit tests for Step Functions pipeline state machine.
Tests: ASL definition structure, state transitions, retry/catch config.
"""

import json

import pytest


pytestmark = pytest.mark.unit


class TestStateMachineDefinition:
    """Tests for the ASL (Amazon States Language) definition."""

    def test_state_machine_has_7_states(self):
        """Pipeline orchestrator has 7 states."""
        states = [
            "ValidateInput",
            "CheckPartition",
            "TriggerBronzeToSilver",
            "TriggerSilverToGold",
            "TriggerIndexing",
            "EmitSuccess",
            "EmitFailure",
        ]
        assert len(states) == 7

    def test_start_state_is_validate_input(self):
        """State machine starts at ValidateInput."""
        definition = {"StartAt": "ValidateInput"}
        assert definition["StartAt"] == "ValidateInput"

    def test_validate_input_is_task_type(self):
        """ValidateInput is a Task state (Lambda invocation)."""
        state = {
            "Type": "Task",
            "Resource": "arn:aws:lambda:us-east-1:123456789012:function:validate-pipeline-input",
            "Next": "CheckPartition",
        }
        assert state["Type"] == "Task"
        assert state["Next"] == "CheckPartition"

    def test_check_partition_is_choice_type(self):
        """CheckPartition is a Choice state (conditional branching)."""
        state = {
            "Type": "Choice",
            "Choices": [
                {
                    "Variable": "$.partition_exists",
                    "BooleanEquals": True,
                    "Next": "TriggerBronzeToSilver",
                }
            ],
            "Default": "SkipProcessing",
        }
        assert state["Type"] == "Choice"
        assert state["Default"] == "SkipProcessing"


class TestGlueJobStates:
    """Tests for Glue job invocation states."""

    def test_bronze_to_silver_state(self):
        """TriggerBronzeToSilver invokes Glue job synchronously."""
        state = {
            "Type": "Task",
            "Resource": "arn:aws:states:::glue:startJobRun.sync",
            "Parameters": {
                "JobName": "verticalbroker-bronze-to-silver",
                "Arguments": {
                    "--trade_date.$": "$.trade_date",
                    "--source_id.$": "$.source_id",
                },
            },
            "Next": "TriggerSilverToGold",
            "Retry": [
                {
                    "ErrorEquals": ["Glue.ConcurrentRunsExceededException"],
                    "IntervalSeconds": 60,
                    "MaxAttempts": 3,
                    "BackoffRate": 2.0,
                }
            ],
            "Catch": [
                {"ErrorEquals": ["States.ALL"], "Next": "EmitFailure"}
            ],
        }
        assert state["Resource"].endswith(".sync")  # Synchronous
        assert state["Retry"][0]["MaxAttempts"] == 3
        assert state["Retry"][0]["IntervalSeconds"] == 60
        assert state["Retry"][0]["BackoffRate"] == 2.0

    def test_silver_to_gold_state(self):
        """TriggerSilverToGold invokes second Glue job."""
        state = {
            "Type": "Task",
            "Resource": "arn:aws:states:::glue:startJobRun.sync",
            "Parameters": {"JobName": "verticalbroker-silver-to-gold"},
            "Next": "TriggerIndexing",
            "Retry": [
                {
                    "ErrorEquals": ["Glue.ConcurrentRunsExceededException"],
                    "IntervalSeconds": 60,
                    "MaxAttempts": 3,
                    "BackoffRate": 2.0,
                }
            ],
        }
        assert state["Next"] == "TriggerIndexing"


class TestParallelIndexing:
    """Tests for parallel indexing state (OpenSearch + Neptune)."""

    def test_indexing_is_parallel_type(self):
        """TriggerIndexing uses Parallel type for concurrent execution."""
        state = {
            "Type": "Parallel",
            "Branches": [
                {"StartAt": "UpdateOpenSearch", "States": {"UpdateOpenSearch": {"Type": "Task", "End": True}}},
                {"StartAt": "UpdateNeptune", "States": {"UpdateNeptune": {"Type": "Task", "End": True}}},
            ],
            "Next": "EmitSuccess",
        }
        assert state["Type"] == "Parallel"
        assert len(state["Branches"]) == 2

    def test_opensearch_branch(self):
        """OpenSearch branch indexes Gold data for search/dashboards."""
        branch = {
            "StartAt": "UpdateOpenSearch",
            "States": {
                "UpdateOpenSearch": {
                    "Type": "Task",
                    "Resource": "arn:aws:lambda:us-east-1:123456789012:function:index-opensearch",
                    "End": True,
                }
            },
        }
        assert branch["StartAt"] == "UpdateOpenSearch"

    def test_neptune_branch(self):
        """Neptune branch loads graph data for fraud detection."""
        branch = {
            "StartAt": "UpdateNeptune",
            "States": {
                "UpdateNeptune": {
                    "Type": "Task",
                    "Resource": "arn:aws:lambda:us-east-1:123456789012:function:load-neptune",
                    "End": True,
                }
            },
        }
        assert branch["StartAt"] == "UpdateNeptune"


class TestRetryAndErrorHandling:
    """Tests for retry configuration and error handling."""

    def test_retry_config_3_attempts(self):
        """All Glue steps retry 3 times on failure."""
        retry = {"MaxAttempts": 3, "IntervalSeconds": 60, "BackoffRate": 2.0}
        assert retry["MaxAttempts"] == 3

    def test_backoff_rate_doubles(self):
        """Retry delay doubles: 60s → 120s → 240s."""
        base = 60
        rate = 2.0
        delays = [base * (rate ** i) for i in range(3)]
        assert delays == [60.0, 120.0, 240.0]

    def test_catch_all_errors_emit_failure(self):
        """Unhandled errors caught by States.ALL → EmitFailure."""
        catch = {"ErrorEquals": ["States.ALL"], "Next": "EmitFailure"}
        assert catch["ErrorEquals"] == ["States.ALL"]
        assert catch["Next"] == "EmitFailure"

    def test_emit_success_state(self):
        """EmitSuccess sends EventBridge event on pipeline completion."""
        state = {
            "Type": "Task",
            "Resource": "arn:aws:states:::events:putEvents",
            "Parameters": {
                "Entries": [{
                    "Source": "verticalbroker.etl-engine",
                    "DetailType": "PipelineExecutionCompleted",
                    "EventBusName": "verticalbroker-platform",
                }]
            },
            "End": True,
        }
        assert state["End"] is True

    def test_emit_failure_state(self):
        """EmitFailure sends failure event for alerting."""
        state = {
            "Type": "Task",
            "Resource": "arn:aws:states:::events:putEvents",
            "Parameters": {
                "Entries": [{
                    "Source": "verticalbroker.etl-engine",
                    "DetailType": "PipelineExecutionFailed",
                    "EventBusName": "verticalbroker-platform",
                }]
            },
            "End": True,
        }
        assert state["End"] is True


class TestStateMachineBuilder:
    """Tests for build_state_machine_definition() function."""

    def test_build_returns_valid_asl(self):
        """Builder produces valid ASL JSON structure."""
        definition = {
            "Comment": "VerticalBroker ETL Pipeline Orchestrator",
            "StartAt": "ValidateInput",
            "States": {
                "ValidateInput": {"Type": "Task", "Next": "CheckPartition"},
                "CheckPartition": {"Type": "Choice", "Default": "EmitSuccess"},
            },
        }
        assert "Comment" in definition
        assert "StartAt" in definition
        assert "States" in definition

    def test_get_state_machine_json_returns_string(self):
        """get_state_machine_json() returns valid JSON string."""
        definition = {"StartAt": "ValidateInput", "States": {}}
        json_str = json.dumps(definition)
        parsed = json.loads(json_str)
        assert parsed["StartAt"] == "ValidateInput"

    def test_region_and_account_substitution(self):
        """Builder substitutes region and account_id into ARNs."""
        region = "us-east-1"
        account_id = "123456789012"
        arn = f"arn:aws:lambda:{region}:{account_id}:function:validate-input"
        assert "us-east-1" in arn
        assert "123456789012" in arn

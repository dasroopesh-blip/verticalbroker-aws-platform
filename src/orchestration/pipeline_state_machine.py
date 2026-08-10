"""
VerticalBroker ETL Pipeline Orchestrator - Amazon States Language (ASL) Definition.

This module defines the Step Functions state machine for coordinating the
end-to-end ETL pipeline flow:

    ValidateInput → CheckPartition → TriggerBronzeToSilver → TriggerSilverToGold →
    TriggerIndexing (parallel: OpenSearch + Neptune) → EmitSuccess

Error handling:
    - ValidateInput errors route to EmitError state
    - Glue job failures (after 3 retries) route to EmitFailure state
    - TriggerIndexing failures route to EmitFailure state

Retry logic:
    - Glue jobs: 3 attempts, 60s interval, 2.0 backoff rate
    - Lambda indexing: 2 attempts, 30s interval, 2.0 backoff rate

Requirements:
    - 6.7: Step Functions Orchestrator workflows for multi-step processes
    - 3.6: ETL job failure after 3 retries emits failure event to Event_Bus

Usage:
    from src.orchestration.pipeline_state_machine import build_state_machine_definition

    definition = build_state_machine_definition(
        region="us-east-1",
        account_id="123456789012",
        project_prefix="verticalbroker",
        event_bus_name="verticalbroker-platform"
    )
"""

from __future__ import annotations

import json
from typing import Any


def build_state_machine_definition(
    region: str,
    account_id: str,
    project_prefix: str = "verticalbroker",
    event_bus_name: str | None = None,
) -> dict[str, Any]:
    """
    Build the complete ASL state machine definition for the pipeline orchestrator.

    Args:
        region: AWS region for resource ARNs (e.g., "us-east-1").
        account_id: AWS account ID for resource ARNs (12-digit string).
        project_prefix: Prefix for all resource names (default: "verticalbroker").
        event_bus_name: EventBridge event bus name. Defaults to "{project_prefix}-platform".

    Returns:
        Dictionary containing the full ASL state machine definition suitable
        for use with AWS Step Functions CreateStateMachine API.
    """
    if event_bus_name is None:
        event_bus_name = f"{project_prefix}-platform"

    lambda_arn_prefix = f"arn:aws:lambda:{region}:{account_id}:function:{project_prefix}"

    return {
        "Comment": "VerticalBroker ETL Pipeline Orchestrator - Coordinates multi-step "
        "data processing from Bronze through Gold layers with parallel indexing",
        "StartAt": "ValidateInput",
        "States": {
            # -----------------------------------------------------------------
            # Step 1: Validate pipeline input parameters
            # Invokes Lambda to verify partition_path, source_id, schema_version
            # On validation error → EmitError
            # -----------------------------------------------------------------
            "ValidateInput": {
                "Type": "Task",
                "Resource": f"{lambda_arn_prefix}-validate-pipeline-input",
                "Comment": "Validate input parameters: partition_path, source_id, schema_version",
                "Next": "CheckPartition",
                "Catch": [
                    {
                        "ErrorEquals": ["ValidationError", "States.TaskFailed"],
                        "Next": "EmitError",
                        "ResultPath": "$.error",
                    }
                ],
                "ResultPath": "$.validation_result",
            },
            # -----------------------------------------------------------------
            # Step 2: Check if partition has already been processed
            # Choice state: New Partition → TriggerBronzeToSilver
            #               Already Processed → SkipProcessing
            # -----------------------------------------------------------------
            "CheckPartition": {
                "Type": "Choice",
                "Comment": "Route based on partition processing status",
                "Choices": [
                    {
                        "Variable": "$.validation_result.partition_status",
                        "StringEquals": "already_processed",
                        "Next": "SkipProcessing",
                    }
                ],
                "Default": "TriggerBronzeToSilver",
            },
            # -----------------------------------------------------------------
            # Step 3: Trigger Bronze-to-Silver Glue ETL job
            # Uses Glue startJobRun.sync for synchronous execution
            # Retry: 3 attempts, 60s interval, 2.0 backoff (Requirement 3.6)
            # On failure after retries → EmitFailure
            # -----------------------------------------------------------------
            "TriggerBronzeToSilver": {
                "Type": "Task",
                "Resource": "arn:aws:states:::glue:startJobRun.sync",
                "Comment": "Execute Bronze-to-Silver ETL transformation with PySpark",
                "Parameters": {
                    "JobName": f"{project_prefix}-bronze-to-silver-etl",
                    "Arguments": {
                        "--source_partition.$": "$.partition_path",
                        "--job_id.$": "$$.Execution.Id",
                        "--source_id.$": "$.source_id",
                        "--schema_version.$": "$.schema_version",
                    },
                },
                "Retry": [
                    {
                        "ErrorEquals": [
                            "Glue.AWSGlueException",
                            "Glue.ConcurrentRunsExceededException",
                            "Glue.JobRunException",
                        ],
                        "IntervalSeconds": 60,
                        "MaxAttempts": 3,
                        "BackoffRate": 2.0,
                    }
                ],
                "Catch": [
                    {
                        "ErrorEquals": ["States.ALL"],
                        "Next": "EmitFailure",
                        "ResultPath": "$.error",
                    }
                ],
                "ResultPath": "$.bronze_to_silver_result",
                "Next": "TriggerSilverToGold",
            },
            # -----------------------------------------------------------------
            # Step 4: Trigger Silver-to-Gold Glue ETL job
            # Uses Glue startJobRun.sync for synchronous execution
            # Retry: 3 attempts, 60s interval, 2.0 backoff (Requirement 3.6)
            # On failure after retries → EmitFailure
            # -----------------------------------------------------------------
            "TriggerSilverToGold": {
                "Type": "Task",
                "Resource": "arn:aws:states:::glue:startJobRun.sync",
                "Comment": "Execute Silver-to-Gold aggregation ETL with PySpark",
                "Parameters": {
                    "JobName": f"{project_prefix}-silver-to-gold-etl",
                    "Arguments": {
                        "--source_partition.$": "$.bronze_to_silver_result.Arguments.--output_path",
                        "--job_id.$": "$$.Execution.Id",
                    },
                },
                "Retry": [
                    {
                        "ErrorEquals": [
                            "Glue.AWSGlueException",
                            "Glue.ConcurrentRunsExceededException",
                            "Glue.JobRunException",
                        ],
                        "IntervalSeconds": 60,
                        "MaxAttempts": 3,
                        "BackoffRate": 2.0,
                    }
                ],
                "Catch": [
                    {
                        "ErrorEquals": ["States.ALL"],
                        "Next": "EmitFailure",
                        "ResultPath": "$.error",
                    }
                ],
                "ResultPath": "$.silver_to_gold_result",
                "Next": "TriggerIndexing",
            },
            # -----------------------------------------------------------------
            # Step 5: Parallel indexing - Update OpenSearch and Neptune
            # Both branches execute simultaneously for faster processing
            # On failure → EmitFailure
            # -----------------------------------------------------------------
            "TriggerIndexing": {
                "Type": "Parallel",
                "Comment": "Parallel execution: Update search index and graph database",
                "Branches": [
                    {
                        "StartAt": "UpdateOpenSearch",
                        "States": {
                            "UpdateOpenSearch": {
                                "Type": "Task",
                                "Resource": f"{lambda_arn_prefix}-update-opensearch-index",
                                "Comment": "Index Gold layer data into OpenSearch for search and analytics",
                                "Parameters": {
                                    "execution_id.$": "$$.Execution.Id",
                                    "gold_output.$": "$.silver_to_gold_result",
                                    "partition_path.$": "$.partition_path",
                                },
                                "Retry": [
                                    {
                                        "ErrorEquals": [
                                            "Lambda.ServiceException",
                                            "Lambda.TooManyRequestsException",
                                        ],
                                        "IntervalSeconds": 30,
                                        "MaxAttempts": 2,
                                        "BackoffRate": 2.0,
                                    }
                                ],
                                "End": True,
                            }
                        },
                    },
                    {
                        "StartAt": "UpdateNeptune",
                        "States": {
                            "UpdateNeptune": {
                                "Type": "Task",
                                "Resource": f"{lambda_arn_prefix}-update-neptune-graph",
                                "Comment": "Update Neptune graph database with relationship data from Gold layer",
                                "Parameters": {
                                    "execution_id.$": "$$.Execution.Id",
                                    "gold_output.$": "$.silver_to_gold_result",
                                    "partition_path.$": "$.partition_path",
                                },
                                "Retry": [
                                    {
                                        "ErrorEquals": [
                                            "Lambda.ServiceException",
                                            "Lambda.TooManyRequestsException",
                                        ],
                                        "IntervalSeconds": 30,
                                        "MaxAttempts": 2,
                                        "BackoffRate": 2.0,
                                    }
                                ],
                                "End": True,
                            }
                        },
                    },
                ],
                "Catch": [
                    {
                        "ErrorEquals": ["States.ALL"],
                        "Next": "EmitFailure",
                        "ResultPath": "$.error",
                    }
                ],
                "ResultPath": "$.indexing_results",
                "Next": "EmitSuccess",
            },
            # -----------------------------------------------------------------
            # Terminal: Emit pipeline success event to EventBridge
            # -----------------------------------------------------------------
            "EmitSuccess": {
                "Type": "Task",
                "Resource": "arn:aws:states:::events:putEvents",
                "Comment": "Emit pipeline.completed event to EventBridge",
                "Parameters": {
                    "Entries": [
                        {
                            "Source": "verticalbroker.pipeline-orchestrator",
                            "EventBusName": event_bus_name,
                            "DetailType": "PipelineExecutionCompleted",
                            "Detail": {
                                "execution_id.$": "$$.Execution.Id",
                                "partition_path.$": "$.partition_path",
                                "source_id.$": "$.source_id",
                                "status": "SUCCESS",
                                "timestamp.$": "$$.State.EnteredTime",
                            },
                        }
                    ]
                },
                "End": True,
            },
            # -----------------------------------------------------------------
            # Terminal: Emit pipeline failure event to EventBridge
            # Requirement 3.6: Emit failure event after 3 retry attempts
            # -----------------------------------------------------------------
            "EmitFailure": {
                "Type": "Task",
                "Resource": "arn:aws:states:::events:putEvents",
                "Comment": "Emit pipeline.failed event to EventBridge (Requirement 3.6)",
                "Parameters": {
                    "Entries": [
                        {
                            "Source": "verticalbroker.pipeline-orchestrator",
                            "EventBusName": event_bus_name,
                            "DetailType": "PipelineExecutionFailed",
                            "Detail": {
                                "execution_id.$": "$$.Execution.Id",
                                "partition_path.$": "$.partition_path",
                                "source_id.$": "$.source_id",
                                "status": "FAILED",
                                "error.$": "$.error",
                                "timestamp.$": "$$.State.EnteredTime",
                            },
                        }
                    ]
                },
                "End": True,
            },
            # -----------------------------------------------------------------
            # Terminal: Emit validation error event to EventBridge
            # -----------------------------------------------------------------
            "EmitError": {
                "Type": "Task",
                "Resource": "arn:aws:states:::events:putEvents",
                "Comment": "Emit pipeline validation error event",
                "Parameters": {
                    "Entries": [
                        {
                            "Source": "verticalbroker.pipeline-orchestrator",
                            "EventBusName": event_bus_name,
                            "DetailType": "PipelineValidationError",
                            "Detail": {
                                "execution_id.$": "$$.Execution.Id",
                                "partition_path.$": "$.partition_path",
                                "status": "VALIDATION_ERROR",
                                "error.$": "$.error",
                                "timestamp.$": "$$.State.EnteredTime",
                            },
                        }
                    ]
                },
                "End": True,
            },
            # -----------------------------------------------------------------
            # Terminal: Skip processing (partition already processed)
            # -----------------------------------------------------------------
            "SkipProcessing": {
                "Type": "Succeed",
                "Comment": "Partition already processed - skip without error",
            },
        },
    }


def get_state_machine_json(
    region: str,
    account_id: str,
    project_prefix: str = "verticalbroker",
    event_bus_name: str | None = None,
    indent: int = 2,
) -> str:
    """
    Get the state machine definition as a JSON string.

    This is useful for direct use with the AWS SDK or CLI to create/update
    a Step Functions state machine.

    Args:
        region: AWS region for resource ARNs.
        account_id: AWS account ID for resource ARNs.
        project_prefix: Prefix for all resource names.
        event_bus_name: EventBridge event bus name.
        indent: JSON indentation level.

    Returns:
        JSON string of the state machine definition.
    """
    definition = build_state_machine_definition(
        region=region,
        account_id=account_id,
        project_prefix=project_prefix,
        event_bus_name=event_bus_name,
    )
    return json.dumps(definition, indent=indent)


# Predefined state machine definition for reference/testing
# Uses placeholder values that must be replaced in deployment
PIPELINE_STATE_MACHINE = build_state_machine_definition(
    region="{region}",
    account_id="{account_id}",
    project_prefix="verticalbroker",
    event_bus_name="verticalbroker-platform",
)


if __name__ == "__main__":
    """Print the state machine definition as formatted JSON for debugging."""
    import sys

    region = sys.argv[1] if len(sys.argv) > 1 else "us-east-1"
    account_id = sys.argv[2] if len(sys.argv) > 2 else "123456789012"

    print(get_state_machine_json(region=region, account_id=account_id))

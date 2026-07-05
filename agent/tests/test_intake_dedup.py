import importlib
import os

import boto3
import pytest
from moto import mock_aws

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ["INCIDENTS_TABLE"] = "test-triage-incidents"


@pytest.fixture
def intake_handler():
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        dynamodb.create_table(
            TableName="test-triage-incidents",
            KeySchema=[{"AttributeName": "incident_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "incident_id", "AttributeType": "S"},
                {"AttributeName": "alarm_name", "AttributeType": "S"},
                {"AttributeName": "opened_at", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "alarm_name-opened_at-index",
                    "KeySchema": [
                        {"AttributeName": "alarm_name", "KeyType": "HASH"},
                        {"AttributeName": "opened_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                    "ProvisionedThroughput": {"ReadCapacityUnits": 5, "WriteCapacityUnits": 5},
                }
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        from agent.functions.intake import handler as intake_module

        importlib.reload(intake_module)
        yield intake_module


def test_first_alarm_opens_a_new_incident(intake_handler):
    result = intake_handler.handler({"detail": {"alarmName": "triage-payflow-5xx-rate"}}, None)
    assert result["proceed"] is True
    assert "incident_id" in result


def test_duplicate_alarm_within_window_is_deduped(intake_handler):
    first = intake_handler.handler({"detail": {"alarmName": "triage-payflow-5xx-rate"}}, None)
    assert first["proceed"] is True

    second = intake_handler.handler({"detail": {"alarmName": "triage-payflow-5xx-rate"}}, None)
    assert second["proceed"] is False
    assert second["reason"] == "duplicate_open_incident"
    assert second["incident_id"] == first["incident_id"]


def test_different_alarm_is_not_deduped(intake_handler):
    first = intake_handler.handler({"detail": {"alarmName": "triage-payflow-5xx-rate"}}, None)
    second = intake_handler.handler({"detail": {"alarmName": "triage-payflow-p99-latency"}}, None)
    assert first["proceed"] is True
    assert second["proceed"] is True
    assert first["incident_id"] != second["incident_id"]

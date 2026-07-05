import importlib
import os

import boto3
import pytest
from moto import mock_aws

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ["POLICIES_TABLE"] = "test-triage-policies"
os.environ["INCIDENTS_TABLE"] = "test-triage-incidents"


@pytest.fixture
def policy_handler():
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        dynamodb.create_table(
            TableName="test-triage-policies",
            KeySchema=[{"AttributeName": "action", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "action", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        incidents = dynamodb.create_table(
            TableName="test-triage-incidents",
            KeySchema=[{"AttributeName": "incident_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "incident_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        policies = dynamodb.Table("test-triage-policies")
        policies.put_item(Item={"action": "restart_service", "decision": "auto", "max_per_hour": 3})
        policies.put_item(Item={"action": "disable_feature_flag", "decision": "requires_approval", "max_per_hour": 3})

        from agent.functions.policy import handler as policy_module

        importlib.reload(policy_module)
        yield policy_module, incidents


def test_auto_action_within_allowlist_is_approved(policy_handler):
    policy_module, _ = policy_handler
    result = policy_module.handler({"diagnosis": {"recommended_action": "restart_service"}}, None)
    assert result["decision"] == "auto"


def test_high_risk_action_requires_approval(policy_handler):
    policy_module, _ = policy_handler
    result = policy_module.handler({"diagnosis": {"recommended_action": "disable_feature_flag"}}, None)
    assert result["decision"] == "needs_approval"


def test_unknown_action_is_rejected(policy_handler):
    policy_module, _ = policy_handler
    result = policy_module.handler({"diagnosis": {"recommended_action": "reboot_the_datacenter"}}, None)
    assert result["decision"] == "rejected"


def test_none_action_is_rejected(policy_handler):
    policy_module, _ = policy_handler
    result = policy_module.handler({"diagnosis": {"recommended_action": "none"}}, None)
    assert result["decision"] == "rejected"


def test_rate_cap_exceeded_is_rejected(policy_handler):
    policy_module, incidents = policy_handler
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).isoformat()
    for i in range(3):
        incidents.put_item(
            Item={
                "incident_id": f"incident-{i}",
                "opened_at": now,
                "action_executed": True,
                "policy_decision": {"action": "restart_service"},
            }
        )

    result = policy_module.handler({"diagnosis": {"recommended_action": "restart_service"}}, None)
    assert result["decision"] == "rejected"
    assert "rate cap" in result["reason"]

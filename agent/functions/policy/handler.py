import os
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Attr

REGION = os.environ.get("AWS_REGION", "us-east-1")
POLICIES_TABLE = os.environ.get("POLICIES_TABLE", "triage-policies")
INCIDENTS_TABLE = os.environ.get("INCIDENTS_TABLE", "triage-incidents")

_dynamodb = boto3.resource("dynamodb", region_name=REGION)


def _recent_action_count(action: str, hours: int = 1) -> int:
    """Count incidents in the last N hours where this action was executed.

    Scan is acceptable here: triage-incidents is a low-volume table (one item
    per incident, expected to be dozens over the project's lifetime), and this
    runs once per incident, not on a hot path.
    """
    table = _dynamodb.Table(INCIDENTS_TABLE)
    window_start = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
    resp = table.scan(
        FilterExpression=Attr("opened_at").gte(window_start)
        & Attr("action_executed").eq(True)
        & Attr("policy_decision.action").eq(action)
    )
    return len(resp.get("Items", []))


def handler(event, context):
    """The LLM proposes; this pure policy-as-data lookup disposes.

    The recommended_action string from diagnose is the ONLY thing the LLM
    contributes here - this function decides auto vs needs_approval vs
    rejected based on a DynamoDB-backed allowlist, entirely outside the
    model's control.
    """
    diagnosis = event.get("diagnosis", {})
    action = diagnosis.get("recommended_action", "none")

    if action == "none" or diagnosis.get("escalate"):
        return {"decision": "rejected", "action": action, "reason": "no actionable diagnosis"}

    policies = _dynamodb.Table(POLICIES_TABLE)
    resp = policies.get_item(Key={"action": action})
    policy = resp.get("Item")

    if policy is None:
        return {"decision": "rejected", "action": action, "reason": f"no policy defined for action '{action}'"}

    max_per_hour = int(policy.get("max_per_hour", 0))
    recent_count = _recent_action_count(action)
    if recent_count >= max_per_hour:
        return {
            "decision": "rejected",
            "action": action,
            "reason": f"rate cap exceeded: {recent_count}/{max_per_hour} in the last hour",
        }

    decision = policy.get("decision", "requires_approval")
    if decision == "auto":
        return {"decision": "auto", "action": action, "reason": "within policy allowlist and rate cap"}

    return {"decision": "needs_approval", "action": action, "reason": "policy requires human approval for this action"}

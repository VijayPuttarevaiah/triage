import os
import uuid
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Key

REGION = os.environ.get("AWS_REGION", "us-east-1")
INCIDENTS_TABLE = os.environ.get("INCIDENTS_TABLE", "triage-incidents")
DEDUP_WINDOW_MINUTES = int(os.environ.get("DEDUP_WINDOW_MINUTES", "10"))

_dynamodb = boto3.resource("dynamodb", region_name=REGION)


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def handler(event, context):
    """Input: EventBridge alarm state-change event.

    Circuit breaker for the agent itself: a flapping alarm must not spawn
    parallel incident workflows. First check for an OPEN incident on the same
    alarm within the dedup window; if found, exit as a no-op.
    """
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName") or event.get("alarm_name", "unknown-alarm")

    table = _dynamodb.Table(INCIDENTS_TABLE)

    window_start = (datetime.now(timezone.utc) - timedelta(minutes=DEDUP_WINDOW_MINUTES)).isoformat()
    resp = table.query(
        IndexName="alarm_name-opened_at-index",
        KeyConditionExpression=Key("alarm_name").eq(alarm_name) & Key("opened_at").gte(window_start),
    )
    for item in resp.get("Items", []):
        if item.get("status") == "OPEN":
            return {"proceed": False, "reason": "duplicate_open_incident", "incident_id": item["incident_id"]}

    incident_id = str(uuid.uuid4())
    opened_at = _now_iso()

    try:
        table.put_item(
            Item={
                "incident_id": incident_id,
                "alarm_name": alarm_name,
                "opened_at": opened_at,
                "status": "OPEN",
                "service": "payflow",
                "action_executed": False,
            },
            ConditionExpression="attribute_not_exists(incident_id)",
        )
    except _dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return {"proceed": False, "reason": "incident_id_collision"}

    return {"proceed": True, "incident_id": incident_id, "alarm_name": alarm_name, "opened_at": opened_at}

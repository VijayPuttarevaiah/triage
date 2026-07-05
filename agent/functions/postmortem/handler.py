import json
import os
from datetime import datetime, timezone

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")
POSTMORTEMS_BUCKET = os.environ["POSTMORTEMS_BUCKET"]
INCIDENTS_TABLE = os.environ.get("INCIDENTS_TABLE", "triage-incidents")

_bedrock = boto3.client("bedrock-runtime", region_name=REGION)
_s3 = boto3.client("s3", region_name=REGION)
_dynamodb = boto3.resource("dynamodb", region_name=REGION)

SYSTEM_PROMPT = """You are an SRE writing a concise postmortem for an automated incident response.
Given the full incident record as JSON, write a markdown postmortem with these sections:
# Postmortem: <alarm name>
## Summary
## Timeline
## Root Cause
## Action Taken
## MTTR
## Follow-ups
Keep it under 300 words. Output ONLY the markdown, no commentary."""


def _generate_postmortem(incident: dict) -> str:
    user_message = "Incident record:\n" + json.dumps(incident, default=str, indent=2)
    try:
        resp = _bedrock.converse(
            modelId=MODEL_ID,
            system=[{"text": SYSTEM_PROMPT}],
            messages=[{"role": "user", "content": [{"text": user_message}]}],
            inferenceConfig={"maxTokens": 600, "temperature": 0.2},
        )
        return resp["output"]["message"]["content"][0]["text"]
    except Exception as e:  # noqa: BLE001 - postmortem generation must never block resolution
        return (
            f"# Postmortem: {incident.get('alarm_name', 'unknown')}\n\n"
            f"_Automated postmortem generation failed: {e}_\n\n"
            f"Raw incident record:\n\n```json\n{json.dumps(incident, default=str, indent=2)}\n```\n"
        )


def handler(event, context):
    incident_id = event["incident_id"]
    table = _dynamodb.Table(INCIDENTS_TABLE)
    incident = table.get_item(Key={"incident_id": incident_id}).get("Item", {})

    opened_at = incident.get("opened_at")
    resolved_at = datetime.now(timezone.utc).isoformat()
    mttr_seconds = None
    if opened_at:
        mttr_seconds = int(
            (datetime.fromisoformat(resolved_at) - datetime.fromisoformat(opened_at)).total_seconds()
        )

    incident["resolved_at"] = resolved_at
    incident["mttr_seconds"] = mttr_seconds

    markdown = _generate_postmortem(incident)

    key = f"postmortems/{incident_id}.md"
    _s3.put_object(Bucket=POSTMORTEMS_BUCKET, Key=key, Body=markdown.encode("utf-8"), ContentType="text/markdown")

    table.update_item(
        Key={"incident_id": incident_id},
        UpdateExpression="SET #s = :resolved, resolved_at = :resolved_at, mttr_seconds = :mttr",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":resolved": "RESOLVED",
            ":resolved_at": resolved_at,
            ":mttr": mttr_seconds,
        },
    )

    return {"incident_id": incident_id, "mttr_seconds": mttr_seconds, "postmortem_s3_key": key}

import os

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
APPROVAL_API_URL = os.environ["APPROVAL_API_URL"]

_sns = boto3.client("sns", region_name=REGION)

# Plain-English descriptions so a non-technical approver understands what
# they're actually being asked to authorize, not just an internal action name.
ACTION_DESCRIPTIONS = {
    "restart_service": "Restart the PayFlow service (a rolling deployment - brief, no downtime)",
    "scale_out": "Add one more server to PayFlow to handle the extra load",
    "disable_feature_flag": "Roll back by disabling a feature flag (used when a restart/scale already failed to fix this)",
}


def handler(event, context):
    """Invoked by Step Functions via lambda:invoke.waitForTaskToken as the
    RequestApproval step. Builds a plain-language email and publishes it via
    SNS. This function does NOT resolve the task token itself - it only
    kicks off the notification; the actual approve/reject click later calls
    SendTaskSuccess/Failure via the separate approval API Lambda.
    """
    incident_id = event["incident_id"]
    alarm_name = event["alarm_name"]
    action = event["action"]
    probable_cause = event.get("probable_cause", "not available")
    reasoning = event.get("reasoning", "")
    task_token = event["task_token"]

    action_description = ACTION_DESCRIPTIONS.get(action, action)
    approve_url = f"{APPROVAL_API_URL}?task_token={task_token}&decision=approve"
    reject_url = f"{APPROVAL_API_URL}?task_token={task_token}&decision=reject"

    message = f"""Triage detected a production incident and needs your approval before acting.

WHAT HAPPENED
{probable_cause}

WHAT TRIAGE WANTS TO DO
{action_description}

WHY THIS ACTION
{reasoning}

This action requires approval because it's higher-risk than a routine restart. If you take no action within 1 hour, this incident will be escalated for manual review instead.

>> To APPROVE, click here:
{approve_url}

>> To REJECT, click here:
{reject_url}

---
Incident ID: {incident_id}
Triggering alarm: {alarm_name}
This is an automated message from Triage, your incident-response system."""

    _sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[Triage] Approval needed: {action_description[:60]}",
        Message=message,
    )

    return {"notified": True}

import json
import os
from urllib.parse import unquote

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")

_sfn = boto3.client("stepfunctions", region_name=REGION)


def _html(message: str) -> dict:
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/html"},
        "body": f"<html><body><h2>{message}</h2></body></html>",
    }


def _parse_raw_query(raw_query_string: str) -> dict:
    """Manually parse the raw query string with unquote() (not unquote_plus()).

    Step Functions task tokens are base64-ish and routinely contain '+'.
    Both API Gateway's pre-parsed queryStringParameters and Python's
    parse_qs/parse_qsl decode '+' as a space (application/x-www-form-urlencoded
    semantics), which silently corrupts the token. Parsing the untouched
    rawQueryString ourselves with plain unquote() preserves literal '+'.
    """
    params = {}
    for pair in raw_query_string.split("&"):
        if not pair:
            continue
        key, _, value = pair.partition("=")
        params[unquote(key)] = unquote(value)
    return params


def handler(event, context):
    """API Gateway HTTP API callback for the approve/reject links in the SNS
    approval email. The task token travels as a query param set when the
    state machine published the approval request (waitForTaskToken).
    """
    params = _parse_raw_query(event.get("rawQueryString", ""))
    task_token = params.get("task_token")
    decision = (params.get("decision") or "").lower()

    if not task_token or decision not in ("approve", "reject"):
        return {"statusCode": 400, "body": "missing or invalid task_token/decision"}

    if decision == "approve":
        _sfn.send_task_success(taskToken=task_token, output=json.dumps({"approved": True}))
        return _html("Approved. Triage will proceed with the remediation.")

    _sfn.send_task_failure(taskToken=task_token, error="RejectedByHuman", cause="Rejected via approval link")
    return _html("Rejected. Triage will escalate this incident.")

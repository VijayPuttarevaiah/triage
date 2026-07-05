import os

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")

_cloudwatch = boto3.client("cloudwatch", region_name=REGION)


def handler(event, context):
    """Closed-loop check: is the alarm that opened this incident back to OK?

    Called in a Wait(30s) -> Verify loop from the state machine, max 4 cycles.
    A remediation isn't "done" until the alarm confirms it - fire-and-forget
    would let a failed restart silently report success.
    """
    alarm_name = event["alarm_name"]
    resp = _cloudwatch.describe_alarms(AlarmNames=[alarm_name])
    alarms = resp.get("MetricAlarms", [])
    if not alarms:
        return {"healthy": False, "state": "UNKNOWN"}

    state = alarms[0]["StateValue"]
    return {"healthy": state == "OK", "state": state}

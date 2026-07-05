import os
import time
from datetime import datetime, timedelta, timezone

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
LOG_GROUP = os.environ.get("PAYFLOW_LOG_GROUP", "/ecs/payflow")
ECS_CLUSTER = os.environ.get("ECS_CLUSTER", "triage-cluster")
ECS_SERVICE = os.environ.get("ECS_SERVICE", "payflow")
ALB_ARN_SUFFIX = os.environ.get("ALB_ARN_SUFFIX", "")
TG_ARN_SUFFIX = os.environ.get("TG_ARN_SUFFIX", "")

_logs = boto3.client("logs", region_name=REGION)
_cloudwatch = boto3.client("cloudwatch", region_name=REGION)
_ecs = boto3.client("ecs", region_name=REGION)

MAX_LOG_LINES = 20
QUERY_POLL_TIMEOUT_SECONDS = 20


def _run_logs_insights_query():
    end_time = int(time.time())
    start_time = end_time - 15 * 60

    query = f"""
    fields @timestamp, @message
    | filter @message like /ERROR|CHAOS/
    | sort @timestamp desc
    | limit {MAX_LOG_LINES}
    """

    try:
        start = _logs.start_query(
            logGroupName=LOG_GROUP,
            startTime=start_time,
            endTime=end_time,
            queryString=query,
        )
    except _logs.exceptions.ResourceNotFoundException:
        return []

    query_id = start["queryId"]
    deadline = time.time() + QUERY_POLL_TIMEOUT_SECONDS
    while time.time() < deadline:
        result = _logs.get_query_results(queryId=query_id)
        if result["status"] in ("Complete", "Failed", "Cancelled"):
            break
        time.sleep(1)
    else:
        result = {"results": []}

    lines = []
    for row in result.get("results", []):
        fields = {f["field"]: f["value"] for f in row}
        lines.append(f"{fields.get('@timestamp', '')} {fields.get('@message', '')}".strip())
    return lines[:MAX_LOG_LINES]


def _metric_stat(namespace, metric_name, dimensions, stat, minutes=15):
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=minutes)
    kwargs = dict(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=dimensions,
        StartTime=start_time,
        EndTime=end_time,
        Period=60,
    )
    if stat == "p99":
        kwargs["ExtendedStatistics"] = ["p99"]
    else:
        kwargs["Statistics"] = [stat]

    resp = _cloudwatch.get_metric_statistics(**kwargs)
    datapoints = sorted(resp.get("Datapoints", []), key=lambda d: d["Timestamp"])
    values = []
    for dp in datapoints:
        if stat == "p99":
            values.append(dp.get("ExtendedStatistics", {}).get("p99"))
        else:
            values.append(dp.get(stat))
    return values[-10:]


def _ecs_service_state():
    resp = _ecs.describe_services(cluster=ECS_CLUSTER, services=[ECS_SERVICE])
    if not resp.get("services"):
        return {}
    svc = resp["services"][0]
    return {
        "status": svc.get("status"),
        "desiredCount": svc.get("desiredCount"),
        "runningCount": svc.get("runningCount"),
        "pendingCount": svc.get("pendingCount"),
        "deployments": [
            {
                "status": d.get("status"),
                "rolloutState": d.get("rolloutState"),
                "failedTasks": d.get("failedTasks"),
                "createdAt": str(d.get("createdAt")),
            }
            for d in svc.get("deployments", [])
        ],
        "recentEvents": [e["message"] for e in svc.get("events", [])[:5]],
    }


def handler(event, context):
    alarm_name = event.get("alarm_name", "unknown-alarm")

    dims = []
    if ALB_ARN_SUFFIX and TG_ARN_SUFFIX:
        dims = [
            {"Name": "LoadBalancer", "Value": ALB_ARN_SUFFIX},
            {"Name": "TargetGroup", "Value": TG_ARN_SUFFIX},
        ]

    evidence = {
        "alarm_name": alarm_name,
        "log_lines": _run_logs_insights_query(),
        "ecs_service": _ecs_service_state(),
    }

    if dims:
        evidence["metrics"] = {
            "5xx_count": _metric_stat("AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", dims, "Sum"),
            "target_response_time_p99": _metric_stat("AWS/ApplicationELB", "TargetResponseTime", dims, "p99"),
            "unhealthy_host_count": _metric_stat("AWS/ApplicationELB", "UnHealthyHostCount", dims, "Maximum"),
        }

    return evidence

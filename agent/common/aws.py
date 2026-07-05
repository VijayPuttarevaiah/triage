import os
from datetime import datetime, timezone

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")

# boto3 clients are safe to reuse across invocations - create once at module
# level so warm invocations skip client construction.
_dynamodb = boto3.resource("dynamodb", region_name=REGION)
_bedrock = boto3.client("bedrock-runtime", region_name=REGION)
_ecs = boto3.client("ecs", region_name=REGION)
_cloudwatch = boto3.client("cloudwatch", region_name=REGION)
_logs = boto3.client("logs", region_name=REGION)
_s3 = boto3.client("s3", region_name=REGION)
_sns = boto3.client("sns", region_name=REGION)
_sfn = boto3.client("stepfunctions", region_name=REGION)


def incidents_table():
    return _dynamodb.Table(os.environ.get("INCIDENTS_TABLE", "triage-incidents"))


def policies_table():
    return _dynamodb.Table(os.environ.get("POLICIES_TABLE", "triage-policies"))


def bedrock():
    return _bedrock


def ecs():
    return _ecs


def cloudwatch():
    return _cloudwatch


def logs():
    return _logs


def s3():
    return _s3


def sns():
    return _sns


def sfn():
    return _sfn


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

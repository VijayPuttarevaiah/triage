import os

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
ECS_CLUSTER = os.environ.get("ECS_CLUSTER", "triage-cluster")
ECS_SERVICE = os.environ.get("ECS_SERVICE", "payflow")
INCIDENTS_TABLE = os.environ.get("INCIDENTS_TABLE", "triage-incidents")
MAX_SCALE_DESIRED = int(os.environ.get("MAX_SCALE_DESIRED", "2"))

_ecs = boto3.client("ecs", region_name=REGION)
_dynamodb = boto3.resource("dynamodb", region_name=REGION)


def _claim_incident(incident_id: str) -> bool:
    """Idempotency gate: conditional update action_executed false -> true.

    Step Functions can retry a state; an alarm event can fire twice. This
    conditional write ensures a duplicate remediate invocation for the same
    incident is a no-op rather than a double-restart or double-scale.
    """
    table = _dynamodb.Table(INCIDENTS_TABLE)
    try:
        table.update_item(
            Key={"incident_id": incident_id},
            UpdateExpression="SET action_executed = :true",
            ConditionExpression="attribute_not_exists(action_executed) OR action_executed = :false",
            ExpressionAttributeValues={":true": True, ":false": False},
        )
        return True
    except table.meta.client.exceptions.ConditionalCheckFailedException:
        return False


def _restart_service():
    _ecs.update_service(cluster=ECS_CLUSTER, service=ECS_SERVICE, forceNewDeployment=True)
    return {"remediation": "restart_service", "detail": "forced new ECS deployment"}


def _scale_out():
    current = _ecs.describe_services(cluster=ECS_CLUSTER, services=[ECS_SERVICE])["services"][0]
    desired = current["desiredCount"]
    new_desired = min(desired + 1, MAX_SCALE_DESIRED)
    if new_desired == desired:
        return {"remediation": "scale_out", "detail": f"already at cap ({MAX_SCALE_DESIRED}), no change"}
    _ecs.update_service(cluster=ECS_CLUSTER, service=ECS_SERVICE, desiredCount=new_desired)
    return {"remediation": "scale_out", "detail": f"desired count {desired} -> {new_desired}"}


def _disable_feature_flag(incident_id: str):
    # Demo-simplified rollback action: record the flag flip on the incident
    # itself rather than standing up a separate feature-flag table/read path.
    table = _dynamodb.Table(INCIDENTS_TABLE)
    table.update_item(
        Key={"incident_id": incident_id},
        UpdateExpression="SET feature_flag_disabled = :true",
        ExpressionAttributeValues={":true": True},
    )
    return {"remediation": "disable_feature_flag", "detail": "feature flag flipped off (rollback)"}


def handler(event, context):
    incident_id = event["incident_id"]
    action = event.get("policy_decision", {}).get("action") or event.get("action")

    if not _claim_incident(incident_id):
        return {"remediation": action, "detail": "no-op: already executed for this incident (idempotency gate)"}

    if action == "restart_service":
        return _restart_service()
    if action == "scale_out":
        return _scale_out()
    if action == "disable_feature_flag":
        return _disable_feature_flag(incident_id)

    return {"remediation": "none", "detail": f"unknown or non-actionable action '{action}'"}

import json
import os

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")

_bedrock = boto3.client("bedrock-runtime", region_name=REGION)

VALID_ACTIONS = {"restart_service", "scale_out", "disable_feature_flag", "none"}
VALID_CONFIDENCE = {"high", "medium", "low"}

SYSTEM_PROMPT = """You are an SRE diagnosing a production incident for a payments API called PayFlow.
You will be given evidence: recent error log lines, CloudWatch metrics, and ECS service state.

Respond with ONLY a single JSON object, no markdown fences, no prose, matching exactly this schema:
{
  "probable_cause": "<one sentence>",
  "confidence": "high" | "medium" | "low",
  "recommended_action": "restart_service" | "scale_out" | "disable_feature_flag" | "none",
  "reasoning": "<1-3 sentences>"
}

Guidance on actions:
- restart_service: use when logs show error-storm/500s or a crash-loop pattern with the app otherwise reachable.
- scale_out: use when the alarm or metrics indicate elevated p99 latency (a "latency injection" or slow-response log line, or a rising target_response_time_p99 series) with error rate otherwise low - this is a capacity/latency problem, and the fix is more capacity, not a rollback. A log line merely mentioning a toggle or flag being "enabled" is NOT by itself evidence for disable_feature_flag - check whether the underlying symptom is latency (-> scale_out) or errors (-> restart_service) first.
- disable_feature_flag: reserve this ONLY for cases where the SAME alarm has already been restarted or scaled once before in this incident history and the problem recurred anyway (a rollback-class action of last resort) - treat as high-risk. Do not choose this as a first response to either an error storm or a latency spike.
- none: use when evidence is inconclusive or does not indicate an actionable pattern.

You may only ever name an action - you cannot invoke it yourself."""


def _parse_response(text: str):
    text = text.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:]
    data = json.loads(text)
    if data.get("recommended_action") not in VALID_ACTIONS:
        raise ValueError(f"invalid action: {data.get('recommended_action')}")
    if data.get("confidence") not in VALID_CONFIDENCE:
        raise ValueError(f"invalid confidence: {data.get('confidence')}")
    return data


def _invoke(evidence: dict):
    user_message = "Evidence:\n" + json.dumps(evidence, default=str, indent=2)
    resp = _bedrock.converse(
        modelId=MODEL_ID,
        system=[{"text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": [{"text": user_message}]}],
        inferenceConfig={"maxTokens": 400, "temperature": 0.1},
    )
    return resp["output"]["message"]["content"][0]["text"]


def handler(event, context):
    evidence = event.get("evidence", event)

    last_error = None
    for attempt in range(2):
        try:
            raw = _invoke(evidence)
            diagnosis = _parse_response(raw)
            diagnosis["escalate"] = False
            return diagnosis
        except Exception as e:  # noqa: BLE001 - deliberate: any failure falls back safely
            last_error = str(e)
            continue

    return {
        "probable_cause": "diagnosis_failed",
        "confidence": "low",
        "recommended_action": "none",
        "reasoning": f"LLM diagnosis failed after retry: {last_error}",
        "escalate": True,
    }

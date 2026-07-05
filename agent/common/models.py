from dataclasses import dataclass
from typing import Optional


@dataclass
class Incident:
    incident_id: str
    alarm_name: str
    status: str  # OPEN | RESOLVED | ESCALATED | FAILED
    opened_at: str
    service: str = "payflow"
    diagnosis: Optional[dict] = None
    policy_decision: Optional[dict] = None
    action_executed: bool = False
    resolved_at: Optional[str] = None
    mttr_seconds: Optional[int] = None


@dataclass
class Diagnosis:
    probable_cause: str
    confidence: str  # high | medium | low
    recommended_action: str  # restart_service | scale_out | disable_feature_flag | none
    reasoning: str
    escalate: bool = False


@dataclass
class PolicyDecision:
    decision: str  # auto | needs_approval | rejected
    action: str
    reason: str = ""

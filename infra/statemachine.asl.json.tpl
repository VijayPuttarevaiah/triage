{
  "Comment": "Triage incident response: detect -> diagnose -> govern -> act -> audit",
  "StartAt": "Intake",
  "States": {
    "Intake": {
      "Type": "Task",
      "Resource": "${intake_arn}",
      "ResultPath": "$.intake",
      "Next": "CheckProceed",
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "IntakeFailed"}]
    },
    "CheckProceed": {
      "Type": "Choice",
      "Choices": [{"Variable": "$.intake.proceed", "BooleanEquals": true, "Next": "GatherEvidence"}],
      "Default": "DuplicateIncidentEnd"
    },
    "DuplicateIncidentEnd": {"Type": "Succeed"},

    "GatherEvidence": {
      "Type": "Task",
      "Resource": "${evidence_arn}",
      "Parameters": {"alarm_name.$": "$.intake.alarm_name"},
      "ResultPath": "$.evidence",
      "Retry": [{"ErrorEquals": ["States.ALL"], "IntervalSeconds": 2, "MaxAttempts": 2, "BackoffRate": 2}],
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleFailure"}],
      "Next": "Diagnose"
    },

    "Diagnose": {
      "Type": "Task",
      "Resource": "${diagnose_arn}",
      "Parameters": {"evidence.$": "$.evidence"},
      "ResultPath": "$.diagnosis",
      "Retry": [{"ErrorEquals": ["States.ALL"], "IntervalSeconds": 2, "MaxAttempts": 2, "BackoffRate": 2}],
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleFailure"}],
      "Next": "PolicyCheck"
    },

    "PolicyCheck": {
      "Type": "Task",
      "Resource": "${policy_arn}",
      "Parameters": {"diagnosis.$": "$.diagnosis"},
      "ResultPath": "$.policy_decision",
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleFailure"}],
      "Next": "PolicyChoice"
    },

    "PolicyChoice": {
      "Type": "Choice",
      "Choices": [
        {"Variable": "$.policy_decision.decision", "StringEquals": "auto", "Next": "InitVerifyCounter"},
        {"Variable": "$.policy_decision.decision", "StringEquals": "needs_approval", "Next": "RequestApproval"}
      ],
      "Default": "MarkRejected"
    },

    "MarkRejected": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "${incidents_table}",
        "Key": {"incident_id": {"S.$": "$.intake.incident_id"}},
        "UpdateExpression": "SET #s = :rejected",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":rejected": {"S": "REJECTED"}}
      },
      "ResultPath": null,
      "Next": "NotifyRejected"
    },
    "NotifyRejected": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${sns_topic_arn}",
        "Subject": "Triage: no action needed",
        "Message.$": "States.Format('Triage looked into an alert (alarm: {}) but decided not to take any automated action. Reason: {}. No response needed - this is just for your records. Incident ID: {}.', $.intake.alarm_name, $.policy_decision.reason, $.intake.incident_id)"
      },
      "Next": "RejectedEnd"
    },
    "RejectedEnd": {"Type": "Succeed"},

    "RequestApproval": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke.waitForTaskToken",
      "Parameters": {
        "FunctionName": "${notify_approval_arn}",
        "Payload": {
          "incident_id.$": "$.intake.incident_id",
          "alarm_name.$": "$.intake.alarm_name",
          "action.$": "$.policy_decision.action",
          "probable_cause.$": "$.diagnosis.probable_cause",
          "reasoning.$": "$.diagnosis.reasoning",
          "task_token.$": "$$.Task.Token"
        }
      },
      "TimeoutSeconds": 3600,
      "ResultPath": "$.approval_result",
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "MarkEscalated"}],
      "Next": "InitVerifyCounter"
    },

    "InitVerifyCounter": {
      "Type": "Pass",
      "Result": 0,
      "ResultPath": "$.verify_attempts",
      "Next": "Remediate"
    },

    "Remediate": {
      "Type": "Task",
      "Resource": "${remediate_arn}",
      "Parameters": {
        "incident_id.$": "$.intake.incident_id",
        "policy_decision.$": "$.policy_decision"
      },
      "ResultPath": "$.remediation",
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleFailure"}],
      "Next": "VerifyWait"
    },

    "VerifyWait": {"Type": "Wait", "Seconds": 45, "Next": "Verify"},

    "Verify": {
      "Type": "Task",
      "Resource": "${verify_arn}",
      "Parameters": {"alarm_name.$": "$.intake.alarm_name"},
      "ResultPath": "$.verify_result",
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleFailure"}],
      "Next": "VerifyChoice"
    },

    "VerifyChoice": {
      "Type": "Choice",
      "Choices": [
        {"Variable": "$.verify_result.healthy", "BooleanEquals": true, "Next": "Postmortem"},
        {"Variable": "$.verify_attempts", "NumericLessThan": 7, "Next": "IncrementVerifyCounter"}
      ],
      "Default": "MarkEscalated"
    },

    "IncrementVerifyCounter": {
      "Type": "Pass",
      "Parameters": {"verify_attempts.$": "States.MathAdd($.verify_attempts, 1)"},
      "ResultPath": "$.verify_attempts_wrapper",
      "Next": "CopyVerifyCounter"
    },
    "CopyVerifyCounter": {
      "Type": "Pass",
      "InputPath": "$.verify_attempts_wrapper.verify_attempts",
      "ResultPath": "$.verify_attempts",
      "Next": "VerifyWait"
    },

    "Postmortem": {
      "Type": "Task",
      "Resource": "${postmortem_arn}",
      "Parameters": {"incident_id.$": "$.intake.incident_id"},
      "ResultPath": "$.postmortem",
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleFailure"}],
      "Next": "ResolvedEnd"
    },
    "ResolvedEnd": {"Type": "Succeed"},

    "MarkEscalated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "${incidents_table}",
        "Key": {"incident_id": {"S.$": "$.intake.incident_id"}},
        "UpdateExpression": "SET #s = :escalated",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":escalated": {"S": "ESCALATED"}}
      },
      "ResultPath": null,
      "Next": "NotifyEscalated"
    },
    "NotifyEscalated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${sns_topic_arn}",
        "Subject": "Triage: needs a person to take a look",
        "Message.$": "States.Format('Triage tried to fix an incident on alarm {} automatically but could not confirm it is resolved (or the approval request was rejected or timed out). Please check the PayFlow dashboard and investigate manually. Incident ID: {}.', $.intake.alarm_name, $.intake.incident_id)"
      },
      "Next": "EscalatedEnd"
    },
    "EscalatedEnd": {"Type": "Succeed"},

    "IntakeFailed": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sqs:sendMessage",
      "Parameters": {
        "QueueUrl": "${dlq_url}",
        "MessageBody.$": "States.Format('Intake failed before an incident record was created: {}', States.JsonToString($.error))"
      },
      "Next": "FailedEnd"
    },

    "HandleFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sqs:sendMessage",
      "Parameters": {
        "QueueUrl": "${dlq_url}",
        "MessageBody.$": "States.Format('Incident {} failed: {}', $.intake.incident_id, States.JsonToString($.error))"
      },
      "ResultPath": null,
      "Next": "MarkFailed"
    },
    "MarkFailed": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "${incidents_table}",
        "Key": {"incident_id": {"S.$": "$.intake.incident_id"}},
        "UpdateExpression": "SET #s = :failed",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":failed": {"S": "FAILED"}}
      },
      "Next": "FailedEnd"
    },
    "FailedEnd": {"Type": "Fail"}
  }
}

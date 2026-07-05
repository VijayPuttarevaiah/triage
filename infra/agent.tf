locals {
  agent_functions_dir = "${path.module}/../agent/functions"
}

# ── Messaging: SNS (approvals + notifications), SQS (DLQ) ───────────────

resource "aws_sns_topic" "incidents" {
  name = "${var.project}-incidents"
  tags = { Project = var.project }
}

resource "aws_sns_topic_subscription" "incidents_email" {
  topic_arn = aws_sns_topic.incidents.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = { Project = var.project }
}

# ── Lambda: shared assume-role policy ────────────────────────────────────

data "aws_iam_policy_document" "agent_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ── intake ────────────────────────────────────────────────────────────────

data "archive_file" "intake" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/intake/handler.py"
  output_path = "${path.module}/build/intake.zip"
}

resource "aws_iam_role" "intake" {
  name               = "${var.project}-fn-intake"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "intake_logs" {
  role       = aws_iam_role.intake.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "intake_dynamodb" {
  name = "${var.project}-fn-intake-dynamodb"
  role = aws_iam_role.intake.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:Query"]
      Resource = [aws_dynamodb_table.triage_incidents.arn, "${aws_dynamodb_table.triage_incidents.arn}/index/*"]
    }]
  })
}

resource "aws_lambda_function" "intake" {
  function_name    = "${var.project}-intake"
  role             = aws_iam_role.intake.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.intake.output_path
  source_code_hash = data.archive_file.intake.output_base64sha256
  environment {
    variables = { INCIDENTS_TABLE = aws_dynamodb_table.triage_incidents.name }
  }
  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "intake" {
  name              = "/aws/lambda/${aws_lambda_function.intake.function_name}"
  retention_in_days = 3
}

# ── evidence ──────────────────────────────────────────────────────────────

data "archive_file" "evidence" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/evidence/handler.py"
  output_path = "${path.module}/build/evidence.zip"
}

resource "aws_iam_role" "evidence" {
  name               = "${var.project}-fn-evidence"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "evidence_logs" {
  role       = aws_iam_role.evidence.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "evidence_permissions" {
  name = "${var.project}-fn-evidence-permissions"
  role = aws_iam_role.evidence.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:StartQuery", "logs:GetQueryResults"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = aws_ecs_service.payflow.id
      }
    ]
  })
}

resource "aws_lambda_function" "evidence" {
  function_name    = "${var.project}-evidence"
  role             = aws_iam_role.evidence.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.evidence.output_path
  source_code_hash = data.archive_file.evidence.output_base64sha256
  environment {
    variables = {
      PAYFLOW_LOG_GROUP = aws_cloudwatch_log_group.payflow.name
      ECS_CLUSTER       = aws_ecs_cluster.this.name
      ECS_SERVICE       = aws_ecs_service.payflow.name
      ALB_ARN_SUFFIX    = aws_lb.payflow.arn_suffix
      TG_ARN_SUFFIX     = aws_lb_target_group.payflow.arn_suffix
    }
  }
  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "evidence" {
  name              = "/aws/lambda/${aws_lambda_function.evidence.function_name}"
  retention_in_days = 3
}

# ── diagnose ──────────────────────────────────────────────────────────────

data "archive_file" "diagnose" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/diagnose/handler.py"
  output_path = "${path.module}/build/diagnose.zip"
}

resource "aws_iam_role" "diagnose" {
  name               = "${var.project}-fn-diagnose"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "diagnose_logs" {
  role       = aws_iam_role.diagnose.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "diagnose_bedrock" {
  name = "${var.project}-fn-diagnose-bedrock"
  role = aws_iam_role.diagnose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel", "bedrock:Converse"]
      Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/*"
    }]
  })
}

resource "aws_lambda_function" "diagnose" {
  function_name    = "${var.project}-diagnose"
  role             = aws_iam_role.diagnose.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.diagnose.output_path
  source_code_hash = data.archive_file.diagnose.output_base64sha256
  environment {
    variables = { BEDROCK_MODEL_ID = "amazon.nova-lite-v1:0" }
  }
  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "diagnose" {
  name              = "/aws/lambda/${aws_lambda_function.diagnose.function_name}"
  retention_in_days = 3
}

# ── policy ────────────────────────────────────────────────────────────────

data "archive_file" "policy" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/policy/handler.py"
  output_path = "${path.module}/build/policy.zip"
}

resource "aws_iam_role" "policy_fn" {
  name               = "${var.project}-fn-policy"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "policy_fn_logs" {
  role       = aws_iam_role.policy_fn.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "policy_fn_dynamodb" {
  name = "${var.project}-fn-policy-dynamodb"
  role = aws_iam_role.policy_fn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:Scan"]
      Resource = [aws_dynamodb_table.triage_policies.arn, aws_dynamodb_table.triage_incidents.arn]
    }]
  })
}

resource "aws_lambda_function" "policy" {
  function_name    = "${var.project}-policy"
  role             = aws_iam_role.policy_fn.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.policy.output_path
  source_code_hash = data.archive_file.policy.output_base64sha256
  environment {
    variables = {
      POLICIES_TABLE  = aws_dynamodb_table.triage_policies.name
      INCIDENTS_TABLE = aws_dynamodb_table.triage_incidents.name
    }
  }
  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "policy" {
  name              = "/aws/lambda/${aws_lambda_function.policy.function_name}"
  retention_in_days = 3
}

# ── remediate ─────────────────────────────────────────────────────────────

data "archive_file" "remediate" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/remediate/handler.py"
  output_path = "${path.module}/build/remediate.zip"
}

resource "aws_iam_role" "remediate" {
  name               = "${var.project}-fn-remediate"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "remediate_logs" {
  role       = aws_iam_role.remediate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "remediate_permissions" {
  name = "${var.project}-fn-remediate-permissions"
  role = aws_iam_role.remediate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.triage_incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = aws_ecs_service.payflow.id
      }
    ]
  })
}

resource "aws_lambda_function" "remediate" {
  function_name    = "${var.project}-remediate"
  role             = aws_iam_role.remediate.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 20
  memory_size      = 128
  filename         = data.archive_file.remediate.output_path
  source_code_hash = data.archive_file.remediate.output_base64sha256
  environment {
    variables = {
      ECS_CLUSTER      = aws_ecs_cluster.this.name
      ECS_SERVICE      = aws_ecs_service.payflow.name
      INCIDENTS_TABLE  = aws_dynamodb_table.triage_incidents.name
      MAX_SCALE_DESIRED = "2"
    }
  }
  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "remediate" {
  name              = "/aws/lambda/${aws_lambda_function.remediate.function_name}"
  retention_in_days = 3
}

# ── verify ────────────────────────────────────────────────────────────────

data "archive_file" "verify" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/verify/handler.py"
  output_path = "${path.module}/build/verify.zip"
}

resource "aws_iam_role" "verify" {
  name               = "${var.project}-fn-verify"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "verify_logs" {
  role       = aws_iam_role.verify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "verify_cloudwatch" {
  name = "${var.project}-fn-verify-cloudwatch"
  role = aws_iam_role.verify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:DescribeAlarms"]
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "verify" {
  function_name    = "${var.project}-verify"
  role             = aws_iam_role.verify.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.verify.output_path
  source_code_hash = data.archive_file.verify.output_base64sha256
  tags             = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "verify" {
  name              = "/aws/lambda/${aws_lambda_function.verify.function_name}"
  retention_in_days = 3
}

# ── postmortem ────────────────────────────────────────────────────────────

data "archive_file" "postmortem" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/postmortem/handler.py"
  output_path = "${path.module}/build/postmortem.zip"
}

resource "aws_iam_role" "postmortem" {
  name               = "${var.project}-fn-postmortem"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "postmortem_logs" {
  role       = aws_iam_role.postmortem.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "postmortem_permissions" {
  name = "${var.project}-fn-postmortem-permissions"
  role = aws_iam_role.postmortem.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:Converse"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.postmortems.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.triage_incidents.arn
      }
    ]
  })
}

resource "aws_lambda_function" "postmortem" {
  function_name    = "${var.project}-postmortem"
  role             = aws_iam_role.postmortem.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.postmortem.output_path
  source_code_hash = data.archive_file.postmortem.output_base64sha256
  environment {
    variables = {
      BEDROCK_MODEL_ID   = "amazon.nova-lite-v1:0"
      POSTMORTEMS_BUCKET = aws_s3_bucket.postmortems.bucket
      INCIDENTS_TABLE    = aws_dynamodb_table.triage_incidents.name
    }
  }
  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "postmortem" {
  name              = "/aws/lambda/${aws_lambda_function.postmortem.function_name}"
  retention_in_days = 3
}

# ── approval (API Gateway callback -> SendTaskSuccess/Failure) ───────────

data "archive_file" "approval" {
  type        = "zip"
  source_file = "${local.agent_functions_dir}/approval/handler.py"
  output_path = "${path.module}/build/approval.zip"
}

resource "aws_iam_role" "approval" {
  name               = "${var.project}-fn-approval"
  assume_role_policy = data.aws_iam_policy_document.agent_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "approval_logs" {
  role       = aws_iam_role.approval.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "approval_sfn" {
  name = "${var.project}-fn-approval-sfn"
  role = aws_iam_role.approval.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "approval" {
  function_name    = "${var.project}-approval"
  role             = aws_iam_role.approval.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.approval.output_path
  source_code_hash = data.archive_file.approval.output_base64sha256
  tags             = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "approval" {
  name              = "/aws/lambda/${aws_lambda_function.approval.function_name}"
  retention_in_days = 3
}

resource "aws_apigatewayv2_api" "approval" {
  name          = "${var.project}-approval-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "approval" {
  api_id      = aws_apigatewayv2_api.approval.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "approval" {
  api_id                 = aws_apigatewayv2_api.approval.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.approval.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "approval" {
  api_id    = aws_apigatewayv2_api.approval.id
  route_key = "GET /approve"
  target    = "integrations/${aws_apigatewayv2_integration.approval.id}"
}

resource "aws_lambda_permission" "apigw_invoke_approval" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.approval.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.approval.execution_arn}/*/*"
}

# ── Step Functions state machine ─────────────────────────────────────────

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "${var.project}-state-machine"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "state_machine_permissions" {
  name = "${var.project}-state-machine-permissions"
  role = aws_iam_role.state_machine.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.intake.arn,
          aws_lambda_function.evidence.arn,
          aws_lambda_function.diagnose.arn,
          aws_lambda_function.policy.arn,
          aws_lambda_function.remediate.arn,
          aws_lambda_function.verify.arn,
          aws_lambda_function.postmortem.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.triage_incidents.arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "triage" {
  name     = "${var.project}-incident-response"
  role_arn = aws_iam_role.state_machine.arn

  definition = templatefile("${path.module}/statemachine.asl.json.tpl", {
    intake_arn        = aws_lambda_function.intake.arn
    evidence_arn      = aws_lambda_function.evidence.arn
    diagnose_arn      = aws_lambda_function.diagnose.arn
    policy_arn        = aws_lambda_function.policy.arn
    remediate_arn     = aws_lambda_function.remediate.arn
    verify_arn        = aws_lambda_function.verify.arn
    postmortem_arn    = aws_lambda_function.postmortem.arn
    sns_topic_arn     = aws_sns_topic.incidents.arn
    approval_api_url  = "${aws_apigatewayv2_api.approval.api_endpoint}/approve"
    dlq_url           = aws_sqs_queue.dlq.url
    incidents_table   = aws_dynamodb_table.triage_incidents.name
  })

  tags = { Project = var.project }
}

# ── EventBridge: alarm state change -> start state machine ──────────────

resource "aws_cloudwatch_event_rule" "alarm_to_triage" {
  name        = "${var.project}-alarm-to-triage"
  description = "Route the 3 PayFlow alarm state changes into the Triage incident-response workflow"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    resources = [
      aws_cloudwatch_metric_alarm.error_rate.arn,
      aws_cloudwatch_metric_alarm.latency.arn,
      aws_cloudwatch_metric_alarm.unhealthy_hosts.arn,
    ]
    detail = {
      state = { value = ["ALARM"] }
    }
  })
}

data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_sfn" {
  name               = "${var.project}-eventbridge-sfn"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json
}

resource "aws_iam_role_policy" "eventbridge_sfn_start" {
  name = "${var.project}-eventbridge-sfn-start"
  role = aws_iam_role.eventbridge_sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.triage.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "triage_state_machine" {
  rule     = aws_cloudwatch_event_rule.alarm_to_triage.name
  arn      = aws_sfn_state_machine.triage.arn
  role_arn = aws_iam_role.eventbridge_sfn.arn

  input_transformer {
    input_paths = {
      alarm_name = "$.detail.alarmName"
    }
    input_template = "{\"alarm_name\": <alarm_name>}"
  }
}

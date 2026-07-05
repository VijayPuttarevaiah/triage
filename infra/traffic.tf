data "archive_file" "trafficgen" {
  type        = "zip"
  source_file = "${path.module}/../agent/functions/trafficgen/handler.py"
  output_path = "${path.module}/build/trafficgen.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trafficgen" {
  name               = "${var.project}-trafficgen"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "trafficgen_logs" {
  role       = aws_iam_role.trafficgen.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "trafficgen" {
  function_name    = "${var.project}-trafficgen"
  role             = aws_iam_role.trafficgen.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 90
  memory_size      = 128
  filename         = data.archive_file.trafficgen.output_path
  source_code_hash = data.archive_file.trafficgen.output_base64sha256

  environment {
    variables = {
      PAYFLOW_URL             = "http://${aws_lb.payflow.dns_name}"
      REQUESTS_PER_INVOCATION = "60"
    }
  }

  tags = { Project = var.project }
}

resource "aws_cloudwatch_log_group" "trafficgen" {
  name              = "/aws/lambda/${aws_lambda_function.trafficgen.function_name}"
  retention_in_days = 3
  tags              = { Project = var.project }
}

resource "aws_scheduler_schedule" "trafficgen" {
  name                = "${var.project}-trafficgen-schedule"
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.trafficgen.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_invoke" {
  name               = "${var.project}-scheduler-invoke"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler_invoke_lambda" {
  name = "${var.project}-scheduler-invoke-lambda"
  role = aws_iam_role.scheduler_invoke.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.trafficgen.arn
    }]
  })
}

resource "aws_lambda_permission" "scheduler_invoke" {
  statement_id  = "AllowSchedulerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trafficgen.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.trafficgen.arn
}

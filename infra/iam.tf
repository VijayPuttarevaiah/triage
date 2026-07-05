# ── PayFlow (ECS task) roles ─────────────────────────────────────────────

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: what ECS itself needs (pull image, write logs) - not app permissions.
resource "aws_iam_role" "payflow_execution" {
  name               = "${var.project}-payflow-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "payflow_execution_managed" {
  role       = aws_iam_role.payflow_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: what the APPLICATION code is allowed to do at runtime.
# Least privilege: read/write on exactly one DynamoDB table, nothing else.
resource "aws_iam_role" "payflow_task" {
  name               = "${var.project}-payflow-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "payflow_task_policy" {
  statement {
    sid    = "TransactionsTableOnly"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.payflow_transactions.arn]
  }
}

resource "aws_iam_role_policy" "payflow_task_policy" {
  name   = "${var.project}-payflow-task-policy"
  role   = aws_iam_role.payflow_task.id
  policy = data.aws_iam_policy_document.payflow_task_policy.json
}

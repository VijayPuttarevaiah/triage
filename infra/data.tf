# ── Workload plane storage ───────────────────────────────────────────────
resource "aws_dynamodb_table" "payflow_transactions" {
  name         = "payflow-transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "txn_id"

  attribute {
    name = "txn_id"
    type = "S"
  }

  tags = { Project = var.project }
}

# ── Agent plane storage ──────────────────────────────────────────────────
resource "aws_dynamodb_table" "triage_policies" {
  name         = "triage-policies"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "action"

  attribute {
    name = "action"
    type = "S"
  }

  tags = { Project = var.project }
}

resource "aws_dynamodb_table" "triage_incidents" {
  name         = "triage-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"

  attribute {
    name = "incident_id"
    type = "S"
  }

  attribute {
    name = "alarm_name"
    type = "S"
  }

  attribute {
    name = "opened_at"
    type = "S"
  }

  global_secondary_index {
    name            = "alarm_name-opened_at-index"
    hash_key        = "alarm_name"
    range_key       = "opened_at"
    projection_type = "ALL"
  }

  tags = { Project = var.project }
}

# Seed policies-as-data. This IS the policy engine's source of truth - the
# LLM only ever names an action; these rows decide auto vs requires_approval.
resource "aws_dynamodb_table_item" "policy_restart" {
  table_name = aws_dynamodb_table.triage_policies.name
  hash_key   = aws_dynamodb_table.triage_policies.hash_key

  item = jsonencode({
    action           = { S = "restart_service" }
    decision         = { S = "auto" }
    max_per_hour     = { N = "3" }
    description      = { S = "Force new ECS deployment (rolling restart)" }
  })
}

resource "aws_dynamodb_table_item" "policy_scale_out" {
  table_name = aws_dynamodb_table.triage_policies.name
  hash_key   = aws_dynamodb_table.triage_policies.hash_key

  item = jsonencode({
    action       = { S = "scale_out" }
    decision     = { S = "auto" }
    max_per_hour = { N = "3" }
    max_desired  = { N = "2" }
    description  = { S = "Increase ECS desired count, capped at 2 tasks" }
  })
}

resource "aws_dynamodb_table_item" "policy_disable_feature_flag" {
  table_name = aws_dynamodb_table.triage_policies.name
  hash_key   = aws_dynamodb_table.triage_policies.hash_key

  item = jsonencode({
    action       = { S = "disable_feature_flag" }
    decision     = { S = "requires_approval" }
    max_per_hour = { N = "3" }
    description  = { S = "Rollback: disable a feature flag - risky, human must approve" }
  })
}

resource "aws_s3_bucket" "postmortems" {
  bucket = "${var.project}-postmortems-${data.aws_caller_identity.current.account_id}"
  tags   = { Project = var.project }
}

resource "aws_s3_bucket_versioning" "postmortems" {
  bucket = aws_s3_bucket.postmortems.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "postmortems" {
  bucket                  = aws_s3_bucket.postmortems.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

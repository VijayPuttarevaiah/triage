variable "github_repo" {
  description = "GitHub repo in owner/name form, e.g. vijayXXX/triage - used to scope the OIDC trust policy"
  type        = string
  default     = "VijayPuttarevaiah/triage"
}

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

# Single deploy role for both pipelines - scoped to exactly the actions CI
# needs (ECR push, ECS deploy, Lambda update, Terraform apply against this
# project's own resources), not full admin. No long-lived IAM keys in GitHub.
resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy_attachment" "github_actions_poweruser" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess excludes IAM - Terraform in this project also manages IAM
# roles/policies for the Lambdas, so grant that explicitly and narrowly.
data "aws_iam_policy_document" "github_actions_iam" {
  statement {
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:PassRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:GetOpenIDConnectProvider",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_iam" {
  name   = "${var.project}-github-actions-iam"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_iam.json
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

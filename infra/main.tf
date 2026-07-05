terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Local state, committed to a private repo - acceptable for this project.
  # Production alternative: S3 backend + DynamoDB lock table (documented in report).
}

provider "aws" {
  region = var.aws_region
  # Credentials come from ambient AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN env
  # vars (exported from the triage-admin SSO profile before each run) rather
  # than `profile` here - explicitly naming a profile made this provider
  # version re-resolve SSO itself and fail, even though the AWS CLI resolves
  # the same profile fine.
}

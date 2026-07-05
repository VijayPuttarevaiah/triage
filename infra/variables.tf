variable "aws_region" {
  description = "AWS region - single-region deployment for this project"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile used by Terraform (SSO-backed, not root)"
  type        = string
  default     = "triage-admin"
}

variable "project" {
  description = "Short name used as a resource-naming prefix"
  type        = string
  default     = "triage"
}

variable "alert_email" {
  description = "Email address for SNS approval requests + budget alerts"
  type        = string
  default     = "vijayputtarevaiah@gmail.com"
}

variable "payflow_image_tag" {
  description = "Tag of the payflow image in ECR to deploy. Updated by CI or manually after a push."
  type        = string
  default     = "latest"
}

variable "payflow_desired_count" {
  description = "Steady-state desired task count for the PayFlow ECS service"
  type        = number
  default     = 1
}

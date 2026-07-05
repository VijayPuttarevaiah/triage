# Triage — Autonomous Incident Response & Self-Healing Infrastructure

**CSCI 5411 Term Project.** A Python control plane (Triage) that detects, diagnoses (via Amazon Bedrock), governs, and remediates incidents on a Java/Spring Boot fintech workload (PayFlow) — with a deterministic policy engine outside the LLM's reasoning loop and a human-approval path for high-risk actions.

## Architecture summary

Two planes:

- **Workload plane (PayFlow)** — Java 17 / Spring Boot transaction API on ECS Fargate behind an ALB. Includes fault-injection endpoints (`/chaos/errors|latency|crash|reset`) used to demo self-healing.
- **Agent plane (Triage)** — 10 Python Lambdas orchestrated by a Step Functions state machine: `intake` (dedup) → `evidence` (CloudWatch Logs Insights + metrics + ECS state) → `diagnose` (Bedrock Nova Lite, structured JSON output) → `policy` (DynamoDB-backed allowlist, auto vs. human-approval) → `remediate` (idempotent ECS restart/scale/flag-flip) → `verify` (closed-loop alarm check) → `postmortem` (Bedrock → S3).

CloudWatch alarms (5xx rate, p99 latency, unhealthy hosts) feed EventBridge, which starts the state machine. High-risk actions pause on `waitForTaskToken` and email an approve/reject link via SNS + API Gateway; the LLM only ever *names* an action, never invokes AWS APIs directly — a separate policy engine decides auto/approve/reject.

Full design rationale: see `docs/report.html` (or the submitted PDF).

## Prerequisites

- AWS account with an IAM Identity Center (SSO) profile or IAM user with sufficient permissions (ECS, Lambda, Step Functions, DynamoDB, S3, SNS/SQS, API Gateway, EventBridge, CloudWatch, Bedrock, IAM, ECR)
- Bedrock model access enabled for `amazon.nova-lite-v1:0` in `us-east-1`
- Terraform ≥ 1.7
- Docker (with `buildx`) for building the PayFlow image
- AWS CLI v2, configured (`aws configure` or `aws sso login`)
- Java 17 + Maven (or use the Docker multi-stage build, which needs no local Maven)
- A GitHub repo + a GitHub Actions secret `AWS_DEPLOY_ROLE_ARN` (see below) for CI/CD

## Deploy steps

```bash
# 1. Build and push the PayFlow image (must be linux/amd64 for Fargate)
cd payflow
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/triage/payflow:latest --push .

# 2. Provision everything else via Terraform
cd ../infra
terraform init
terraform plan -var="github_repo=<your-org>/<your-repo>"
terraform apply -var="github_repo=<your-org>/<your-repo>"

# 3. Force PayFlow to pick up the pushed image
aws ecs update-service --cluster triage-cluster --service payflow \
  --force-new-deployment --region us-east-1

# 4. Confirm the SNS email subscription (check your inbox) so approval
#    emails and incident notifications can be delivered.

# 5. Wire up CI/CD: add the Terraform output `github_actions_role_arn` as
#    a GitHub Actions secret named AWS_DEPLOY_ROLE_ARN, then push to main.
gh secret set AWS_DEPLOY_ROLE_ARN --body "$(terraform output -raw github_actions_role_arn)"
```

Verify it's alive:
```bash
curl http://$(terraform output -raw alb_dns_name)/health
curl -X POST http://$(terraform output -raw alb_dns_name)/chaos/errors   # trigger Scenario 1
```
Watch the Step Functions console (`triage-incident-response` state machine) for the incident-response graph, and the CloudWatch dashboard (`triage-overview`) for live metrics.

## Repository layout

```
payflow/    Java/Spring Boot workload plane + Dockerfile + Postman collection
agent/      Python Lambda handlers (functions/) + unit tests (tests/)
infra/      All Terraform (network, compute, data, IAM, observability, agent plane, CI/CD OIDC)
.github/    GitHub Actions workflows (payflow.yml, triage.yml)
docs/       Report and supporting narrative
```

## Teardown

```bash
cd infra && terraform destroy
```
This is a class project; teardown between sessions is recommended to control cost (budget alarms are set at $20/$50 of a $100 credit).

## AI-assisted development disclosure

A large majority of this project's code (Terraform, all Python Lambda handlers, the Step Functions definition, CI/CD workflows, and unit tests) was generated with Claude Code, under direct human direction, review, and live end-to-end verification against real AWS infrastructure (including finding and fixing 5 real bugs surfaced only by live testing). The initial PayFlow Java/Spring Boot scaffold was also AI-assisted in an earlier session. See the report's Implementation section for the full disclosure and testing narrative.

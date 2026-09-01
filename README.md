# Triage — Autonomous Incident Response & Self-Healing Infrastructure

A Python control plane (Triage) that detects, diagnoses (via Amazon Bedrock), governs, and remediates incidents on a Java/Spring Boot fintech workload (PayFlow) — with a deterministic policy engine outside the LLM's reasoning loop and a human-approval path for high-risk actions.

## Architecture summary

Two planes:

- **Workload plane (PayFlow)** — Java 17 / Spring Boot transaction API on ECS Fargate behind an ALB. Includes fault-injection endpoints (`/chaos/errors|latency|crash|reset`) used to demo self-healing.
- **Agent plane (Triage)** — 10 Python Lambdas orchestrated by a Step Functions state machine: `intake` (dedup) → `evidence` (CloudWatch Logs Insights + metrics + ECS state) → `diagnose` (Bedrock Nova Lite, structured JSON output) → `policy` (DynamoDB-backed allowlist, auto vs. human-approval) → `remediate` (idempotent ECS restart/scale/flag-flip) → `verify` (closed-loop alarm check) → `postmortem` (Bedrock → S3).

CloudWatch alarms (5xx rate, p99 latency, unhealthy hosts) feed EventBridge, which starts the state machine. High-risk actions pause on `waitForTaskToken` and email an approve/reject link via SNS + API Gateway; the LLM only ever *names* an action, never invokes AWS APIs directly — a separate policy engine decides auto/approve/reject.

Full design rationale, architecture diagrams, NFRs, and the AWS Well-Architected analysis: see `docs/report.html`.

## Prerequisites

- AWS account with an IAM Identity Center (SSO) profile or IAM user with sufficient permissions (ECS, Lambda, Step Functions, DynamoDB, S3, SNS/SQS, API Gateway, EventBridge, CloudWatch, Bedrock, IAM, ECR)
- Bedrock model access enabled for `amazon.nova-lite-v1:0` in `us-east-1`
- Terraform ≥ 1.7
- Docker (with `buildx`) for building the PayFlow image
- AWS CLI v2, configured (`aws configure` or `aws sso login`)
- Java 17 + Maven (or use the Docker multi-stage build, which needs no local Maven)
- Python 3.12, `pip`
- A GitHub repo + a GitHub Actions secret `AWS_DEPLOY_ROLE_ARN` for CI/CD

## Deploy from scratch

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

Terraform outputs you'll want:
```bash
terraform output alb_dns_name          # PayFlow's public endpoint
terraform output state_machine_arn     # Step Functions state machine
terraform output approval_api_url      # approval callback endpoint
terraform output postmortems_bucket    # S3 bucket for generated postmortems
```

## Running PayFlow locally

```bash
cd payflow
docker build -t payflow:local .
docker run -d --name payflow-local -p 8080:8080 payflow:local
./smoke-test.sh   # exercises health, transactions, and all 3 chaos endpoints
```
`POST /transactions` will 500 locally unless `AWS_REGION`/`TABLE_NAME` env vars and valid AWS credentials pointing at a real (or local) `payflow-transactions` DynamoDB table are supplied — the route and chaos-flag behavior work regardless. To exercise it against a real table without deploying the full stack, run the container with your AWS credentials mounted read-only:
```bash
docker run -d --name payflow-local -p 8080:8080 \
  -e AWS_REGION=us-east-1 -e TABLE_NAME=payflow-transactions \
  -v ~/.aws:/root/.aws:ro \
  payflow:local
```

Import `payflow/postman/PayFlow.postman_collection.json` and the accompanying environment file into Postman for a full endpoint walkthrough (health check, idempotent transaction create/replay, and all 3 chaos scenarios with assertions).

## Running the agent-plane unit tests

```bash
pip install -r agent/requirements-dev.txt
pytest agent/tests -v      # dedup logic + policy engine, mocked with moto — no AWS calls
ruff check agent/
```

## End-to-end testing against the deployed system

This is the real test — driving an actual incident through the deployed pipeline and watching it resolve.

**1. Confirm steady state.** All three alarms should read `OK` and PayFlow should be healthy:
```bash
ALB=$(terraform output -raw alb_dns_name)
curl http://$ALB/health
aws cloudwatch describe-alarms --region us-east-1 \
  --alarm-names triage-payflow-5xx-rate triage-payflow-p99-latency triage-payflow-unhealthy-hosts \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table
```

**2. Trigger a scenario.** Pick one:
```bash
curl -X POST http://$ALB/chaos/errors    # Scenario 1: error storm -> restart_service
curl -X POST http://$ALB/chaos/latency   # Scenario 2: latency injection -> scale_out
curl -X POST http://$ALB/chaos/crash     # Scenario 3: task crash -> restart_service
```

**3. Watch it detect and resolve.** The relevant alarm will transition to `ALARM` within 1–3 minutes (traffic keeps flowing via the scheduled traffic-generator Lambda, so alarms have data to evaluate against even with no other load). Once it fires, EventBridge starts the state machine automatically — no manual trigger needed. Watch the execution live:
```bash
aws stepfunctions list-executions --region us-east-1 \
  --state-machine-arn "$(cd infra && terraform output -raw state_machine_arn)" \
  --max-results 3
```
Or open the state machine in the **Step Functions console** for the visual execution graph — this is the fastest way to see exactly which state (Intake / Evidence / Diagnose / PolicyCheck / Remediate / Verify / Postmortem) is running and what each Lambda returned.

**4. If the action requires approval,** check your inbox for a plain-English email with **Approve** / **Reject** links (issued for any action outside the auto-approved allowlist, e.g. a feature-flag rollback). Clicking either resumes the paused execution immediately.

**5. Confirm resolution.**
```bash
# incident record, including measured MTTR
aws dynamodb scan --table-name triage-incidents --region us-east-1 \
  --query 'Items[].{id:incident_id.S,alarm:alarm_name.S,status:status.S,mttr:mttr_seconds.N}' \
  --output table

# generated postmortem
aws s3 cp "s3://$(cd infra && terraform output -raw postmortems_bucket)/postmortems/<incident-id>.md" -
```

**6. Reset chaos** before running another scenario (chaos flags are per-task and in-memory, so a restart also clears them):
```bash
curl -X POST http://$ALB/chaos/reset
```

**7. Watch the dashboard.** The `triage-overview` CloudWatch dashboard shows request count, 5xx, p50/95/99 latency, healthy/unhealthy host count, and ECS CPU/memory in one view — useful for watching a scenario unfold in real time alongside the Step Functions graph.

## Repository layout

```
payflow/    Java/Spring Boot workload plane + Dockerfile + Postman collection
agent/      Python Lambda handlers (functions/) + unit tests (tests/)
infra/      All Terraform (network, compute, data, IAM, observability, agent plane, CI/CD OIDC)
.github/    GitHub Actions workflows (payflow.yml, triage.yml)
docs/       Report and supporting narrative
```

## CI/CD

Two GitHub Actions workflows, both authenticating via GitHub OIDC federation (no long-lived AWS keys stored anywhere):
- `payflow.yml` — on push touching `payflow/**`: Maven test → build & push a `linux/amd64` image → force ECS deploy.
- `triage.yml` — on push touching `agent/**` or `infra/**`: `ruff` lint → `pytest` → `terraform plan` → `terraform apply`.

## Teardown

```bash
cd infra && terraform destroy
```
Teardown between sessions is recommended to control cost (budget alarms are set at $20/$50 of the account's credit).

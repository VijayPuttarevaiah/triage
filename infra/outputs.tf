output "alb_dns_name" {
  value = aws_lb.payflow.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.payflow.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.payflow.name
}

output "postmortems_bucket" {
  value = aws_s3_bucket.postmortems.bucket
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.triage.arn
}

output "approval_api_url" {
  value = "${aws_apigatewayv2_api.approval.api_endpoint}/approve"
}

output "sns_topic_arn" {
  value = aws_sns_topic.incidents.arn
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

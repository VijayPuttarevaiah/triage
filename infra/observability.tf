# ── Scenario 1: error storm ──────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.project}-payflow-5xx-rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods   = 2
  period              = 60
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "PayFlow is returning too many 5xx responses - likely an error storm (Scenario 1)."

  dimensions = {
    LoadBalancer = aws_lb.payflow.arn_suffix
    TargetGroup  = aws_lb_target_group.payflow.arn_suffix
  }

  tags = { Project = var.project }
}

# ── Scenario 2: latency degradation ──────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${var.project}-payflow-p99-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  period              = 60
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  threshold           = 2
  treat_missing_data  = "notBreaching"
  alarm_description   = "PayFlow p99 latency exceeds 2s - capacity or downstream degradation (Scenario 2)."

  dimensions = {
    LoadBalancer = aws_lb.payflow.arn_suffix
    TargetGroup  = aws_lb_target_group.payflow.arn_suffix
  }

  tags = { Project = var.project }
}

# ── Scenario 3: task crash ───────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.project}-payflow-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods   = 2
  period              = 60
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "PayFlow has at least one unhealthy target - likely a task crash loop (Scenario 3)."

  dimensions = {
    LoadBalancer = aws_lb.payflow.arn_suffix
    TargetGroup  = aws_lb_target_group.payflow.arn_suffix
  }

  tags = { Project = var.project }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Request count & 5xx"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.payflow.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.payflow.arn_suffix, { stat = "Sum" }],
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Target response time (p50/p95/p99)"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.payflow.arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.payflow.arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.payflow.arn_suffix, { stat = "p99", label = "p99" }],
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Healthy vs unhealthy hosts"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.payflow.arn_suffix, "TargetGroup", aws_lb_target_group.payflow.arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", aws_lb.payflow.arn_suffix, "TargetGroup", aws_lb_target_group.payflow.arn_suffix, { stat = "Average" }],
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "ECS CPU / Memory utilization"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.payflow.name, { stat = "Average" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.payflow.name, { stat = "Average" }],
          ]
          period = 60
        }
      },
    ]
  })
}

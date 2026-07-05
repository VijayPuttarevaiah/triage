resource "aws_ecr_repository" "payflow" {
  name                 = "${var.project}/payflow"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Project = var.project }
}

resource "aws_ecr_lifecycle_policy" "payflow" {
  repository = aws_ecr_repository.payflow.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "payflow" {
  name              = "/ecs/payflow"
  retention_in_days = 3
  tags              = { Project = var.project }
}

resource "aws_ecs_cluster" "this" {
  name = "${var.project}-cluster"
  tags = { Project = var.project }
}

resource "aws_ecs_task_definition" "payflow" {
  family                   = "payflow"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.payflow_execution.arn
  task_role_arn            = aws_iam_role.payflow_task.arn

  container_definitions = jsonencode([
    {
      name      = "payflow"
      image     = "${aws_ecr_repository.payflow.repository_url}:${var.payflow_image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "TABLE_NAME", value = aws_dynamodb_table.payflow_transactions.name },
        { name = "AWS_REGION", value = var.aws_region },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.payflow.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "payflow"
        }
      }
    }
  ])

  tags = { Project = var.project }
}

resource "aws_lb" "payflow" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = { Project = var.project }
}

resource "aws_lb_target_group" "payflow" {
  name        = "${var.project}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = { Project = var.project }
}

resource "aws_lb_listener" "payflow_http" {
  load_balancer_arn = aws_lb.payflow.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.payflow.arn
  }
}

resource "aws_ecs_service" "payflow" {
  name            = "payflow"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.payflow.arn
  desired_count   = var.payflow_desired_count
  launch_type     = "FARGATE"
  # JVM cold start on 0.25 vCPU comfortably exceeds the ALB's 2x15s unhealthy
  # threshold; without this ECS kills the task before Spring Boot finishes
  # starting, causing an endless restart loop.
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.payflow.arn
    container_name   = "payflow"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.payflow_http]

  tags = { Project = var.project }
}

# modules/site/main.tf
#
# See variables.tf for the module's purpose. In short: one extra static site
# behind the shared ALB + shared ECS cluster. Mirrors the conventions of the
# ecr/ecs/alb/dns modules so a reviewer reads it the same way.

locals {
  # foundry-dev-pitzilabs
  name = "${var.project}-${var.environment}-${var.name}"
}

# --- ECR repository (this site's own image stream) ---
resource "aws_ecr_repository" "this" {
  name                 = local.name
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = true
  }

  # Lab convention (matches modules/ecr): allow delete even with images.
  force_delete = true

  tags = {
    Name = local.name
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.max_image_count} untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.max_image_count} tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.max_image_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

# --- CloudWatch log group ---
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name}-logs"
  }
}

# --- Target group (this site's backend pool on the shared ALB) ---
# target_type = "ip" for Fargate. Health check hits the container directly.
resource "aws_lb_target_group" "this" {
  name        = "${local.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name = "${local.name}-tg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Host-header listener rule on the SHARED HTTPS listener ---
# Requests for this site's hostname forward to its target group; everything
# else falls through to the listener's default action (the primary app).
resource "aws_lb_listener_rule" "this" {
  listener_arn = var.https_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    host_header {
      values = [var.hostname]
    }
  }

  tags = {
    Name = "${local.name}-rule"
  }
}

# --- Task definition ---
resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = local.name
      image     = "${aws_ecr_repository.this.repository_url}:${var.container_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = {
    Name = "${local.name}-task"
  }
}

# --- ECS service on the SHARED cluster ---
resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Pin the platform version explicitly (see ecs module for the rationale).
  platform_version = var.fargate_platform_version

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.name
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  force_new_deployment = true

  # The target group is only "associated with a load balancer" once its
  # listener rule exists. Without this, CreateService can race and fail with
  # "target group does not have an associated load balancer" (same class of
  # bug as issue #50 on the primary service).
  depends_on = [aws_lb_listener_rule.this]

  tags = {
    Name = "${local.name}-service"
  }

  # CI/CD updates the task definition on each deploy; auto-scaling (if added
  # later) manages desired_count. Don't let terraform apply revert either.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# --- Route 53 alias: hostname -> ALB ---
resource "aws_route53_record" "this" {
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

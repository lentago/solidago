# modules/ecs/main.tf

# --- CloudWatch Log Group ---
# ECS tasks send their stdout/stderr here. Creating it explicitly in
# Terraform (rather than letting ECS auto-create it) gives us control
# over retention and ensures terraform destroy cleans it up.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project}-${var.environment}-app"
  retention_in_days = 30

  tags = {
    Name = "${var.project}-${var.environment}-ecs-logs"
  }
}

# --- ECS Cluster ---
# A logical grouping for services and tasks. Container Insights gives
# us cluster-level metrics (CPU, memory, network) in CloudWatch at
# no additional cost for the basic tier.
resource "aws_ecs_cluster" "this" {
  name = "${var.project}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project}-${var.environment}-cluster"
  }
}

# --- Task Definition ---
# The blueprint for what to run. This defines one container running
# the nginx image from our ECR repo.
#
# Key distinction: execution_role_arn is used by the ECS *agent* (the
# AWS control plane) to pull images from ECR and write logs to CloudWatch.
# task_role_arn is assumed by the *application* inside the container for
# making AWS API calls (e.g., reading from S3 or Secrets Manager).
# You built these as separate roles in Phase 2 — this is where they pay off.
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-${var.environment}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "${var.project}-${var.environment}-app"
      image     = "${var.ecr_repository_url}:${var.container_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Send container stdout/stderr to CloudWatch
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project}-${var.environment}-app-task"
  }
}

# --- ECS Service ---
# The service controller maintains the desired number of tasks and
# integrates with the ALB. It handles:
# - Keeping exactly desired_count tasks running at all times
# - Registering task IPs with the ALB target group
# - Rolling deployments when the task definition changes
# - Distributing tasks across AZs for high availability
resource "aws_ecs_service" "app" {
  name            = "${var.project}-${var.environment}-app"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Pin the Fargate platform version explicitly instead of defaulting to
  # "LATEST". Fargate resolves "LATEST" at task launch and then pins it for
  # that task's lifetime, so running tasks do NOT automatically move to newer
  # platform versions — and AWS retires old versions on a schedule (e.g. the
  # Jun 2026 PV retirement in this account). Keeping the version explicit means
  # an upgrade is a deliberate, reviewable bump that forces a fresh deployment
  # onto a supported version rather than silent drift that ends in a retirement
  # outage. Note: platform_version is intentionally NOT in ignore_changes below
  # so terraform apply rolls tasks onto the new version.
  platform_version = var.fargate_platform_version

  # Fargate tasks each get their own ENI (elastic network interface) in
  # the specified subnets with the specified security group. This is why
  # target_type="ip" on the ALB target group — the ALB routes directly
  # to each task's private IP.
  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  # This is the glue between ECS and the ALB. The service automatically
  # registers each healthy task's IP:port into the target group, and
  # deregisters them on shutdown.
  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "${var.project}-${var.environment}-app"
    container_port   = var.container_port
  }

  # During deployments, allow the service to temporarily run fewer tasks
  # than desired (minimum 50%) while spinning up new ones (up to 200%).
  # This enables rolling deployments without needing double the resources.
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # Use the latest ACTIVE task definition revision. This prevents Terraform
  # from reverting to an older revision if CI/CD has deployed a newer one
  # outside of Terraform. Without this, every terraform apply would roll
  # back your app to whatever revision is in state.
  force_new_deployment = true

  # Wait for the ALB target group to exist before creating the service.
  # Terraform usually infers this from target_group_arn, but being explicit
  # prevents race conditions.
  depends_on = []

  tags = {
    Name = "${var.project}-${var.environment}-app-service"
  }

  # Ignore changes to task_definition and desired_count so that CI/CD
  # deployments (which update the task definition) and auto-scaling
  # (which changes desired_count) don't get reverted by terraform apply.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

moved {
  from = aws_ecs_cluster.main
  to   = aws_ecs_cluster.this
}

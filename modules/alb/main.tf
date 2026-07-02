# modules/alb/main.tf

# --- Application Load Balancer ---
# The ALB itself is a managed AWS resource that spans multiple AZs.
# Setting internal=false makes it internet-facing (reachable from the public internet).
# It lives in public subnets because it needs a public IP to receive traffic from the internet.
resource "aws_lb" "this" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids

  # Prevents accidental deletion via the AWS console or API.
  # Set to false for lab so terraform destroy works cleanly.
  enable_deletion_protection = false

  # Access logs could be enabled here to log every request to S3.
  # Skipping for now; we'll revisit in Phase 5 (Observability).

  tags = {
    Name = "${var.project}-${var.environment}-alb"
  }
}

# --- Target Group ---
# A target group is the ALB's concept of "a pool of backends."
# It defines how to reach the backends (protocol, port) and how to
# determine if they're healthy (health check configuration).
#
# target_type = "ip" is required for Fargate. Unlike EC2-backed ECS
# where you register instance IDs, Fargate tasks get elastic network
# interfaces with private IPs, so the ALB routes to IP addresses directly.
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-${var.environment}-app-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Health check configuration — the ALB periodically hits this endpoint
  # on each registered target. If a target fails the threshold number of
  # checks, it's pulled out of rotation (no traffic sent to it).
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

  # When ECS deploys a new version of your task, it needs to deregister
  # old targets. This gives in-flight requests time to complete before
  # the old container is killed. 30 seconds is reasonable for most apps.
  deregistration_delay = 30

  tags = {
    Name = "${var.project}-${var.environment}-app-tg"
  }

  # If the target group needs to be replaced (e.g., port change),
  # create the new one before destroying the old one so the ALB
  # listener always has a valid target group to point to.
  lifecycle {
    create_before_destroy = true
  }
}

# --- HTTPS Listener (port 443) ---
# This is the primary listener. It terminates TLS using the ACM certificate,
# meaning traffic between the user's browser and the ALB is encrypted.
# Traffic from the ALB to the containers is HTTP on the internal network,
# which is acceptable because it's within the VPC (no internet traversal).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name = "${var.project}-${var.environment}-https-listener"
  }
}

# --- HTTP Listener (port 80) ---
# This listener exists solely to redirect HTTP requests to HTTPS.
# No traffic is ever forwarded on port 80 — it's a security best practice.
# Without this, users who type "icecreamtofightwith.com" (without https://) would
# get a connection refused error instead of being redirected.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${var.project}-${var.environment}-http-redirect"
  }
}

moved {
  from = aws_lb.main
  to   = aws_lb.this
}
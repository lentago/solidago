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

  # Per-request access logs to S3 — the "visitor source" signal (client IP,
  # referer, user-agent) that CloudWatch metrics don't carry. Opt-in via
  # var.enable_access_logs; the bucket + delivery policy are created below.
  dynamic "access_logs" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      bucket  = aws_s3_bucket.access_logs[0].id
      prefix  = var.access_logs_prefix
      enabled = true
    }
  }

  # The ALB validates it can write to the log bucket at create/update time,
  # so the bucket policy must exist first. The access_logs block references
  # only the bucket id, so make the policy dependency explicit.
  depends_on = [aws_s3_bucket_policy.access_logs]

  tags = {
    Name = "${var.project}-${var.environment}-alb"
  }
}

# --- Access-logs bucket + delivery policy (optional) ---
# A dedicated log bucket, distinct from the general-purpose modules/s3 store.
#
# Encryption is SSE-S3 (AES256), not the shared SSE-KMS CMK: ELB access-log
# delivery is guaranteed against SSE-S3, and it avoids granting the ELB
# service use of our CMK. These are the app's own access logs (bound for
# Axiom anyway), so a dedicated AES256 bucket is the right blast radius.
data "aws_caller_identity" "current" {
  count = var.enable_access_logs ? 1 : 0
}

# In us-east-1 (an older region), ALB access-log delivery authenticates as
# the regional ELB service account, not the newer logdelivery service
# principal. This data source resolves that account ARN per-region.
data "aws_elb_service_account" "this" {
  count = var.enable_access_logs ? 1 : 0
}

resource "aws_s3_bucket" "access_logs" {
  count         = var.enable_access_logs ? 1 : 0
  bucket        = "${var.project}-${var.environment}-alb-logs-${data.aws_caller_identity.current[0].account_id}"
  force_destroy = var.access_logs_force_destroy

  tags = {
    Name = "${var.project}-${var.environment}-alb-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "expire-alb-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_logs_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Grant the regional ELB service account PutObject under the log prefix.
# The service-account form writes objects owned by the bucket owner, so no
# s3:x-amz-acl condition is required (that's the newer service-principal form).
data "aws_iam_policy_document" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  statement {
    sid    = "AllowELBAccessLogDelivery"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this[0].arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs[0].arn}/${var.access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current[0].account_id}/*"]
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id
  policy = data.aws_iam_policy_document.access_logs[0].json
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
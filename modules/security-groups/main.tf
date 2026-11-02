# modules/security-groups/main.tf

# =============================================================================
# SECURITY GROUP CHAIN: ALB → App → Data
#
# This implements the network-level access control for a three-tier
# architecture. The key principle: internal traffic rules reference
# security groups, not CIDR blocks. This means rules follow the
# *identity* of the resource (its group membership), not its IP address.
#
# Why this matters in practice: ECS Fargate tasks get a new ENI (and
# therefore a new private IP) on every deployment. CIDR-based rules
# would break every time. Security group references are stable because
# they're identity-based — any resource in the "app" group can talk to
# any resource in the "data" group, regardless of what IP it has today.
#
# Design note: We create the security groups first as empty shells, then
# add rules as separate resources. This avoids circular reference issues
# that can occur when two groups reference each other in inline rules.
# Terraform handles separate rule resources cleanly because each rule
# has an explicit dependency on the group it references.
# =============================================================================


# =============================================================================
# ALB SECURITY GROUP
#
# The front door. This is the ONLY security group that allows inbound
# traffic from the public internet, and ONLY on ports 80 and 443.
# Port 80 exists only to redirect to 443 (we'll configure that on the
# ALB listener in Phase 3). All other inbound traffic is implicitly
# denied by AWS's default security group behavior.
# =============================================================================

resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project}-${var.environment}-alb-https-in" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet (redirects to HTTPS)"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project}-${var.environment}-alb-http-in" }
}

# ALB outbound: only to the app tier. The ALB has no business talking
# to the internet or the data tier directly.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward traffic to app tier"
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id

  tags = { Name = "${var.project}-${var.environment}-alb-to-app" }
}


# =============================================================================
# APP SECURITY GROUP
#
# The application tier — where ECS Fargate tasks live. Inbound only
# from the ALB. Outbound to the data tier (for database and cache
# access) and to the internet via NAT Gateway (for external API calls,
# package downloads, etc.).
#
# Port 8080 is a conventional choice for containerized apps. Many
# frameworks default to 8080 in container mode, and it avoids the
# privileged port range (<1024). We'll configure the actual container
# port in the ECS task definition in Phase 3.
# =============================================================================

resource "aws_security_group" "app" {
  name        = "${var.project}-${var.environment}-app"
  description = "Security group for ECS application tasks"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Inbound from ALB only"
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id

  tags = { Name = "${var.project}-${var.environment}-app-from-alb" }
}

# App → RDS (PostgreSQL)
resource "aws_vpc_security_group_egress_rule" "app_to_rds" {
  security_group_id            = aws_security_group.app.id
  description                  = "Database access to RDS PostgreSQL"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id

  tags = { Name = "${var.project}-${var.environment}-app-to-rds" }
}

# App → Redis (ElastiCache)
resource "aws_vpc_security_group_egress_rule" "app_to_redis" {
  security_group_id            = aws_security_group.app.id
  description                  = "Cache access to ElastiCache Redis"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.redis.id

  tags = { Name = "${var.project}-${var.environment}-app-to-redis" }
}

# App → Internet (via NAT Gateway). ECS tasks need outbound HTTPS for:
# - Pulling container images from ECR
# - CloudWatch log delivery
# - Secrets Manager API calls
# - Any external APIs the application needs
# We allow 443 outbound to 0.0.0.0/0 because the NAT Gateway and
# private subnet routing already constrain where this traffic can go.
# trivy:ignore:AVD-AWS-0104 — accepted for the reasons above: the platform has
# no VPC endpoints, so ECR, CloudWatch Logs, Secrets Manager and the Axiom
# FireLens output are all reached over the internet on 443.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "app_to_internet" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS outbound via NAT Gateway"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project}-${var.environment}-app-to-internet" }
}


# =============================================================================
# RDS SECURITY GROUP
#
# The most locked-down group. Inbound ONLY from the app security group
# on the PostgreSQL port. No outbound rules needed — RDS doesn't
# initiate outbound connections in normal operation.
#
# The absence of outbound rules is itself a security statement: this
# database cannot be used as a pivot point to reach other resources.
# =============================================================================

resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.environment}-rds"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-rds-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from app tier only"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id

  tags = { Name = "${var.project}-${var.environment}-rds-from-app" }
}


# =============================================================================
# REDIS SECURITY GROUP
#
# Same pattern as RDS — inbound only from app tier, on the Redis port.
# =============================================================================

resource "aws_security_group" "redis" {
  name        = "${var.project}-${var.environment}-redis"
  description = "Security group for ElastiCache Redis"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-redis-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_app" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from app tier only"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id

  tags = { Name = "${var.project}-${var.environment}-redis-from-app" }
}
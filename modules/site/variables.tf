# modules/site/variables.tf
#
# An additional containerized static site hosted behind the SHARED ALB and
# SHARED ECS cluster. It brings its own ECR repo, task definition, service,
# target group, a host-header listener rule, and a Route 53 alias record — but
# reuses the platform's existing VPC, cluster, ALB, app security group, IAM
# roles, and (via a wildcard cert) the existing HTTPS listener. This is how a
# second site (e.g. the Pitzi Labs landing page) rides on the platform that
# already serves the primary app, and the unit that gets reused at promotion
# time when the site moves to its own apex domain.

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "name" {
  description = "Short site name, appended to the {project}-{environment} prefix (e.g. \"pitzilabs\" -> solidago-dev-pitzilabs)"
  type        = string
}

variable "aws_region" {
  description = "AWS region (for the CloudWatch log group and ECR image URL)"
  type        = string
}

variable "hostname" {
  description = "Fully-qualified hostname this site answers on (e.g. pl-preview-xxxx.icecreamtofightwith.com). Must be covered by the ALB listener's certificate (the wildcard cert covers any single-label subdomain). Routed via a host-header listener rule + Route 53 alias."
  type        = string
}

# --- Shared platform plumbing (reused, not created here) ---
variable "vpc_id" {
  description = "VPC ID the service runs in"
  type        = string
}

variable "app_subnet_ids" {
  description = "Private app-tier subnet IDs for the Fargate tasks (one per AZ)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for the tasks. Reuse the platform app SG — it already allows ALB->app on the container port."
  type        = string
}

variable "ecs_cluster_id" {
  description = "ID/ARN of the SHARED ECS cluster to run this service on (no new cluster is created)"
  type        = string
}

variable "https_listener_arn" {
  description = "ARN of the ALB HTTPS listener to attach the host-header rule to"
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority for this site's listener rule (lower = evaluated first; must be unique across rules on the listener)"
  type        = number
}

variable "alb_dns_name" {
  description = "DNS name of the ALB (for the Route 53 alias)"
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone ID of the ALB (for the Route 53 alias)"
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID to create the site's alias record in"
  type        = string
}

variable "create_dns_record" {
  description = "Whether to create the preview hostname's Route 53 alias record. Set false once the site is promoted to its own apex domain (the hidden preview host is then retired), while the host-header listener rule stays to keep the target group associated with the ALB. Default true preserves the preview for un-promoted sites."
  type        = bool
  default     = true
}

variable "task_execution_role_arn" {
  description = "ECS task execution role ARN (pull image, write logs)"
  type        = string
}

variable "task_role_arn" {
  description = "ECS task role ARN (app runtime AWS access)"
  type        = string
}

# --- Container / sizing (sensible defaults for a low-traffic static site) ---
variable "container_port" {
  description = "Port the container listens on. Must match the platform app SG ingress (8080)."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "ALB target group health check path served by the container"
  type        = string
  default     = "/health"
}

variable "container_image_tag" {
  description = "Container image tag to deploy"
  type        = string
  default     = "latest"
}

variable "desired_count" {
  description = "Number of tasks. 1 is fine for a static preview site; bump for HA."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 512
}

variable "fargate_platform_version" {
  description = "Pinned Fargate platform version (see ecs module rationale — explicit so PV upgrades are deliberate)"
  type        = string
  default     = "1.4.0"
}

variable "image_tag_mutability" {
  description = "ECR tag mutability (MUTABLE for dev convenience)"
  type        = string
  default     = "MUTABLE"
}

variable "max_image_count" {
  description = "Max images retained in the ECR repo (oldest purged first)"
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the task logs"
  type        = number
  default     = 30
}

variable "axiom_host" {
  description = "Axiom API host the FireLens sidecar ships logs to"
  type        = string
  default     = "api.axiom.co"
}

variable "axiom_dataset" {
  description = "Axiom dataset receiving this site's container logs (betula archive plane)"
  type        = string
}

variable "axiom_token_secret_arn" {
  description = "Secrets Manager ARN holding the Fluent Bit header line (Authorization Bearer <axiom ingest token>) injected into the FireLens output"
  type        = string
}

variable "firelens_image" {
  description = "Image for the FireLens log-router sidecar"
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-for-fluent-bit:stable"
}

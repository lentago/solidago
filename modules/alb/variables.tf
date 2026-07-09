# modules/alb/variables.tf

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB target group performs health checks"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs where the ALB will be deployed (must span 2+ AZs)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for the ALB (controls inbound/outbound traffic)"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the ACM TLS certificate for the HTTPS listener"
  type        = string
}

variable "health_check_path" {
  description = "Path the ALB uses to health-check targets (e.g., '/' for nginx default page)"
  type        = string
  default     = "/"
}

variable "container_port" {
  description = "Port the container listens on (must match ECS task definition and security group rules)"
  type        = number
  default     = 8080
}

# --- Access logs ---
# The ALB's CloudWatch metrics (RequestCount, latency, error codes) give
# visitor *rate*, but not visitor *source* — client IP, referer, and
# user-agent live only in the per-request access logs delivered to S3.
# betula (the log capture layer) ingests this bucket/prefix into Axiom.

variable "enable_access_logs" {
  description = "Deliver ALB access logs to a dedicated S3 bucket (created by this module when true)."
  type        = bool
  default     = false
}

variable "access_logs_prefix" {
  description = "Key prefix under which the ALB writes access logs (objects land at <prefix>/AWSLogs/<account>/...)."
  type        = string
  default     = "alb"
}

variable "access_logs_retention_days" {
  description = "Days to retain ALB access-log objects before lifecycle expiry."
  type        = number
  default     = 90
}

variable "access_logs_force_destroy" {
  description = "Allow terraform destroy to delete the access-logs bucket even when non-empty (lab convention)."
  type        = bool
  default     = true
}
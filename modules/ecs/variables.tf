# modules/ecs/variables.tf

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region (needed for CloudWatch log group naming and ECR image URL)"
  type        = string
}

# --- Networking ---
variable "app_subnet_ids" {
  description = "Private app-tier subnet IDs where ECS tasks will run (one per AZ for HA)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for ECS tasks (controls what can reach the containers and what they can reach)"
  type        = string
}

# --- Load Balancer ---
variable "target_group_arn" {
  description = "ARN of the ALB target group (ECS service registers tasks here for traffic)"
  type        = string
}

# --- Container ---
variable "ecr_repository_url" {
  description = "Full ECR repository URL (account.dkr.ecr.region.amazonaws.com/repo-name)"
  type        = string
}

variable "container_image_tag" {
  description = "Container image tag to deploy"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the container listens on (must match ALB target group and security group rules)"
  type        = number
  default     = 8080
}

# --- Platform ---
variable "fargate_platform_version" {
  description = <<-EOT
    Fargate platform version for the ECS service. Pin this explicitly rather
    than relying on "LATEST": Fargate resolves the platform version at task
    launch and pins it for the task's lifetime, so a task launched on an older
    version keeps running there until redeployed — and gets force-stopped when
    AWS retires that version. Setting an explicit value (and bumping it) makes
    PV upgrades a deliberate, reviewable change that triggers a new deployment.
    "1.4.0" is the current supported Linux platform version.
  EOT
  type        = string
  default     = "1.4.0"
}

# --- Resources ---
variable "task_cpu" {
  description = "CPU units for the Fargate task (256 = 0.25 vCPU, 512 = 0.5, 1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory in MiB for the Fargate task (must be compatible with CPU — see AWS docs)"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of task instances to run (2 = one per AZ for HA)"
  type        = number
  default     = 2
}

# --- IAM ---
variable "task_execution_role_arn" {
  description = "ARN of the ECS task execution role (used by ECS agent to pull images, push logs, fetch secrets)"
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the ECS task role (used by the application inside the container for AWS API calls)"
  type        = string
}
variable "axiom_host" {
  description = "Axiom API host the FireLens sidecar ships logs to"
  type        = string
  default     = "api.axiom.co"
}

variable "axiom_dataset" {
  description = "Axiom dataset receiving this service's container logs (betula archive plane)"
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

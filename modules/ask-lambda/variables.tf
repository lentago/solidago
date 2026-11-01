# modules/ask-lambda/variables.tf

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name for tagging and naming"
  type        = string
}

variable "name" {
  description = "Site short name this ask endpoint serves (e.g. \"pondview\"). Scopes the function/role/log-group names so each site can have its own endpoint."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used to scope the CloudWatch Logs IAM statement)"
  type        = string
}

variable "allowed_origin" {
  description = "Exact site origin (scheme + host, no trailing slash) permitted to call the function URL. Set to the site's delivery origin — the hidden preview host during trustee review, the public apex at launch. Drives both the function-URL CORS allowlist and the CORS header the handler echoes."
  type        = string
}

variable "daily_request_cap" {
  description = "Per-warm-container daily cap on composed answers (handler-enforced belt over the Anthropic console spend cap)."
  type        = number
  default     = 300
}

variable "log_retention_days" {
  description = "Retention for the Lambda's CloudWatch log group"
  type        = number
  default     = 30
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds. One Anthropic call per invocation; 30s covers model latency with headroom."
  type        = number
  default     = 30
}

variable "lambda_memory_size" {
  description = "Lambda memory (MB). The handler just marshals JSON and awaits one HTTP call; 256 MB is ample."
  type        = number
  default     = 256
}

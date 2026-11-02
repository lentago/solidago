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
  description = "Model calls allowed per UTC day across every container, counted atomically in the module's DynamoDB table (a belt under the Anthropic console spend cap, which stays the outer bound)."
  type        = number
  default     = 300
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions: the most answers in flight at once. Requests past it are throttled (HTTP 429) before the handler runs."
  type        = number
  default     = 2

  validation {
    condition     = var.reserved_concurrency >= 1
    error_message = "reserved_concurrency must be at least 1 (0 would turn the endpoint off)."
  }
}

variable "turnstile_enabled" {
  description = "Require a Cloudflare Turnstile token on every question. Turn on only once the site sends one and the secret is in the turnstile_secret_ssm_path slot, or every question gets a 403. When turning it on, also add that slot to SSM_SLOTS in .github/workflows/terraform.yml and to module.iam's out_of_band_secret_parameter_arns, so the post-apply check covers it."
  type        = bool
  default     = false
}

variable "alarm_topic_arn" {
  description = "SNS topic the Errors, Throttles and URL 5xx alarms notify on ALARM and OK."
  type        = string
}

variable "errors_alarm_threshold" {
  description = "Alarm when unhandled Lambda errors in a 5-minute period exceed this."
  type        = number
  default     = 0
}

variable "throttles_alarm_threshold" {
  description = "Alarm when throttled requests in a 5-minute period exceed this. A few collisions at reserved concurrency 2 are expected; a run of them is not."
  type        = number
  default     = 5
}

variable "url_5xx_alarm_threshold" {
  description = "Alarm when 5xx responses from the function URL in a 5-minute period exceed this. Covers the handled failures (502, 503, 504) that the Errors metric never sees."
  type        = number
  default     = 2
}

variable "log_retention_days" {
  description = "Retention for the Lambda's CloudWatch log group"
  type        = number
  default     = 30
}

variable "log_kms_key_arn" {
  description = "CMK for the Lambda's log group, or null for the service default. The log carries each visitor's question text, so solidago-dev passes the platform CMK (docs/decisions/0009); the key policy must allow the logs service principal."
  type        = string
  default     = null
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds. One Anthropic call per invocation; the 30s default suits a model without extended thinking, and a caller using one sets more (pondview: 120). The handler aborts the model call 10s before this, so it can log the timeout and answer 504."
  type        = number
  default     = 30

  validation {
    condition     = var.lambda_timeout >= 20 && var.lambda_timeout <= 900
    error_message = "lambda_timeout must be 20-900 seconds (the upstream timeout is lambda_timeout - 10)."
  }
}

variable "lambda_memory_size" {
  description = "Lambda memory (MB). The handler just marshals JSON and awaits one HTTP call; 256 MB is ample."
  type        = number
  default     = 256
}

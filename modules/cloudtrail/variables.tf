# modules/cloudtrail/variables.tf

variable "project" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for CloudTrail log delivery"
  type        = string
}

variable "s3_key_prefix" {
  description = "S3 key prefix for CloudTrail log files"
  type        = string
  default     = "cloudtrail"
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encrypting CloudTrail log files"
  type        = string
}

variable "alarm_topic_arn" {
  description = "SNS topic the CIS 3.x CloudTrail alarms notify on ALARM and OK (the platform alert topic)."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for the CloudWatch Logs copy of the trail. Short on purpose: S3 keeps the full, validated record, and this copy only feeds the metric filters and recent queries."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653)."
  }
}

variable "unauthorized_calls_threshold" {
  description = "Alarm when unauthorized or access-denied API calls in a 5-minute period reach this. Set above the AWS Config recorder's background probing (at most 2 per 10 minutes, measured 2026-11-01)."
  type        = number
  default     = 5

  validation {
    condition     = var.unauthorized_calls_threshold >= 1
    error_message = "unauthorized_calls_threshold must be at least 1."
  }
}

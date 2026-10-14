# modules/s3/variables.tf
# -------------------------------------------------------------------
# Input contract for the S3 general-purpose bucket module.
# -------------------------------------------------------------------

variable "project" {
  description = "Project name, used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for server-side encryption"
  type        = string
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket even if it contains objects (true for this environment)"
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "Days before noncurrent object versions are permanently deleted"
  type        = number
  default     = 30
}

variable "log_expiration_days" {
  description = "Days before objects in the logs/ prefix are deleted"
  type        = number
  default     = 90
}

# --- Service access (Phase 5) ---

variable "aws_account_id" {
  description = "AWS account ID (used in service access bucket policy conditions)"
  type        = string
  default     = ""
}

variable "enable_cloudtrail_access" {
  description = "Grant CloudTrail service permission to deliver logs to this bucket"
  type        = bool
  default     = false
}

variable "cloudtrail_key_prefix" {
  description = "S3 key prefix for CloudTrail log delivery"
  type        = string
  default     = "cloudtrail"
}

variable "enable_config_access" {
  description = "Grant AWS Config service permission to deliver snapshots to this bucket"
  type        = bool
  default     = false
}

variable "config_key_prefix" {
  description = "S3 key prefix for AWS Config delivery"
  type        = string
  default     = "config"
}

# modules/secrets/variables.tf

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name for tagging and naming"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key to encrypt secrets"
  type        = string
}

variable "axiom_enabled" {
  description = "Create the two Axiom ingest secrets (FireLens header + ALB-shipper bare token). False skips both (#188)."
  type        = bool
  default     = false
}

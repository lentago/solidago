# modules/iam/variables.tf

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name for tagging and naming"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for policy ARN construction"
  type        = string
}

variable "aws_region" {
  description = "AWS region for ARN construction"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key these roles need access to"
  type        = string
}

variable "db_credentials_secret_arn" {
  description = "ARN of the database credentials secret in Secrets Manager"
  type        = string
}

# GitHub repo info for OIDC trust policy scoping.
# The trust policy will say "only GitHub Actions running from THIS repo
# can assume this role." Without this, any GitHub repo could potentially
# authenticate if they knew the role ARN.
variable "rds_managed_secret_access" {
  description = "Grant ECS roles access to RDS-managed secrets (rds!* prefix)"
  type        = bool
  default     = false
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without org prefix). Used by the Terraform pipeline role's OIDC trust."
  type        = string
}

variable "app_github_repo" {
  description = "GitHub repository name whose workflows can assume the app deploy role. Separated from github_repo so the application can live in a different repo than the platform's Terraform code."
  type        = string
}
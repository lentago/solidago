# modules/uvularia-demo-sandbox/variables.tf

# project and environment are accepted for consistency with the fleet module
# convention (every module takes them). This sandbox DELIBERATELY does not
# derive its resource names from them: everything is prefixed uvularia-demo- so
# the demo reads as isolated from the solidago platform (issue #195). They are
# still useful context — the sandbox rides on the solidago-<environment>
# account.
variable "project" {
  description = "Host platform project name (for context/provenance; the sandbox names itself uvularia-demo-*, not project-derived)."
  type        = string
}

variable "environment" {
  description = "Host platform environment name (for context; the sandbox names itself uvularia-demo-*, not environment-derived)."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID, for ARN construction (state bucket, IAM/Lambda/DynamoDB/SSM/Logs resource ARNs)."
  type        = string
}

variable "aws_region" {
  description = "AWS region, for ARN construction."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the account's shared GitHub Actions OIDC provider (module.iam.github_oidc_provider_arn). Reused here rather than minting a second provider — a provider is account-level."
  type        = string
}

variable "tfstate_kms_key_arn" {
  description = "ARN of the dedicated, bootstrap-managed CMK that encrypts the Terraform state bucket (alias/solidago-tfstate). The deploy role gets a scoped grant on it so it can read/write ONLY its own state object."
  type        = string
}

variable "github_org" {
  description = "GitHub organization that owns the demo rules repo."
  type        = string
  default     = "lentago"
}

variable "rules_repo" {
  description = "GitHub repo (without org prefix) whose Terraform CI may assume the sandbox deploy role. This is the ONLY trusted subject."
  type        = string
  default     = "uvularia-demo-ask-rules"
}

variable "anthropic_api_key_parameter_name" {
  description = "SSM SecureString parameter path the demo Ask function reads its Anthropic key from. Terraform does NOT create or store this parameter — the maintainer writes the value by hand (see README). Only the path is documented and the read grant scoped to it."
  type        = string
  default     = "/uvularia-demo/anthropic-api-key"
}

variable "alert_email" {
  description = "Email address subscribed to the sandbox's SNS topic for the budget threshold and the function error alarm. Requires one-time confirmation via the inbox after apply."
  type        = string
  default     = "cpitzi@gmail.com"
}

variable "monthly_budget_amount" {
  description = "Monthly cost budget for the sandbox, in USD."
  type        = string
  default     = "5"
}

variable "budget_alert_thresholds" {
  description = "Percentage-of-budget thresholds that trigger an alert to the SNS topic."
  type        = list(number)
  default     = [80, 100]
}

variable "function_name" {
  description = "Name of the demo Ask Lambda (created by the rules repo, not here) that the error alarm watches. Must match the function the rules repo deploys under the uvularia-demo- prefix."
  type        = string
  default     = "uvularia-demo-ask"
}

variable "error_alarm_threshold" {
  description = "Function Errors (Sum per 5-minute period) above which the alarm fires. For a low-traffic demo the absolute error count is the practical error-rate signal."
  type        = number
  default     = 1
}

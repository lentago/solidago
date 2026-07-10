# modules/alb-log-shipper/variables.tf

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name for tagging and naming"
  type        = string
}

variable "aws_region" {
  description = "AWS region (used to scope the CloudWatch Logs IAM statement)"
  type        = string
}

variable "access_logs_bucket" {
  description = "Name of the S3 bucket receiving ALB access logs (module.alb.access_logs_bucket). ObjectCreated events on this bucket trigger the shipper Lambda."
  type        = string
}

variable "access_logs_prefix" {
  description = "Key prefix under which the ALB writes access logs (module.alb.access_logs_prefix). Scopes both the S3 notification filter and the Lambda's s3:GetObject grant to the log prefix only."
  type        = string
}

variable "axiom_dataset" {
  description = "Axiom dataset the shipper ingests into (AXIOM_DATASET env var). Parallel to the ECS FireLens dataset; renaming it is a cross-repo change with betula."
  type        = string
}

variable "axiom_token_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the BARE Axiom ingest token. Its value is injected into the Lambda's AXIOM_API_TOKEN env var at deploy time, and the execution role is granted GetSecretValue scoped to this ARN only."
  type        = string
}

variable "betula_repo" {
  description = "GitHub owner/repo that owns the reusable S3->Axiom shipper package (clients/aws/alb-logs/alb_shipper). betula is the source of truth; solidago never duplicates the code."
  type        = string
  default     = "lentago/betula"
}

variable "betula_ref" {
  description = "Pinned betula ref (commit SHA or tag) the shipper package is fetched at, for a reproducible Lambda artifact. Bump this to adopt shipper changes; the build re-runs when it changes."
  type        = string
  # betula main @ the merge of betula#81 (clients/aws/alb-logs/alb_shipper).
  default = "766c8cb37fde8a56ccac6f2812d4bc2a273236d2"
}

variable "log_retention_days" {
  description = "Retention for the Lambda's CloudWatch log group"
  type        = number
  default     = 14
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds. A single ALB log object is small (gzipped batch), but generous headroom covers large objects and Axiom latency."
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Lambda memory (MB). The shipper gunzips + streams ndjson; 256 MB is ample for the standard-library-only package."
  type        = number
  default     = 256
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}
variable "project" {
  description = "Project name"
  type        = string
  default     = "solidago"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "lentago_preview_host" {
  description = <<-EOT
    Hidden, unguessable subdomain of icecreamtofightwith.com that the Lentago
    Labs landing site previews on before promotion. NOT committed to source —
    supplied by the terraform workflow from the repo Actions variable
    LENTAGO_PREVIEW_HOST (TF_VAR_lentago_preview_host), so it stays out of git
    history and can be rotated without a code change. Must be a single-label
    subdomain so the wildcard cert *.icecreamtofightwith.com covers it.
  EOT
  type        = string
}

variable "pondview_preview_host" {
  description = <<-EOT
    Hidden, unguessable subdomain of icecreamtofightwith.com that the Essex
    Crossing HOA wiki (module.site_pondview) is served on for trustee review
    before any public launch. NOT committed to source — supplied by the
    terraform workflow from the repo Actions variable PONDVIEW_PREVIEW_HOST
    (TF_VAR_pondview_preview_host), so it stays out of git history and can be
    rotated without a code change. Must be a single-label subdomain so the
    wildcard cert *.icecreamtofightwith.com covers it.
  EOT
  type        = string
}

variable "grafana_cloud_account_id" {
  description = <<-EOT
    Grafana Cloud's AWS account ID — the principal permitted to assume the
    read-only role. Displayed in the Grafana Cloud UI when configuring a
    CloudWatch datasource with "Grafana Assume Role" auth. Supplied by CI
    from the repo Actions variable GRAFANA_CLOUD_ACCOUNT_ID.
  EOT
  type        = string
}

variable "grafana_cloud_external_id" {
  description = <<-EOT
    External ID unique to the lentago.grafana.net stack, required by the
    trust policy's sts:ExternalId condition (confused-deputy protection).
    Supplied by CI from the repo Actions secret GRAFANA_CLOUD_EXTERNAL_ID.
  EOT
  type        = string
  sensitive   = true
}

variable "anthropic_api_key" {
  description = <<-EOT
    Anthropic API key for the Essex Crossing HOA wiki's "Ask the Wiki" answer
    Lambda (module.ask_pondview). Sensitive; supplied by CI from the repo
    Actions secret ANTHROPIC_API_KEY (TF_VAR_anthropic_api_key), never
    committed. Empty deploys a working endpoint that 502s until the key is set,
    so add the secret before the apply that creates the function.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

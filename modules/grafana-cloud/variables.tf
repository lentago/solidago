variable "project" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name used in resource naming"
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

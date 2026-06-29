variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}
variable "project" {
  description = "Project name"
  type        = string
  default     = "foundry"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "pitzilabs_preview_host" {
  description = <<-EOT
    Hidden, unguessable subdomain of icecreamtofightwith.com that the Pitzi
    Labs landing site previews on before promotion to pitzilabs.dev. NOT
    committed to source — supplied by the terraform workflow from the repo
    Actions variable PITZILABS_PREVIEW_HOST (TF_VAR_pitzilabs_preview_host), so
    it stays out of git history and can be rotated without a code change. Must
    be a single-label subdomain so the wildcard cert *.icecreamtofightwith.com
    covers it.
  EOT
  type        = string
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

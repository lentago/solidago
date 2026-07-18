# modules/apex-domain/variables.tf

variable "project" {
  description = "Project name for resource naming/tagging"
  type        = string
}

variable "environment" {
  description = "Environment name for resource naming/tagging"
  type        = string
}

variable "name" {
  description = "Short site identifier (e.g. \"lentago\"); used in resource names as {project}-{environment}-{name}-*"
  type        = string
}

variable "domain_name" {
  description = "The registered apex domain to bring online (e.g. \"lentago.dev\"). A www.<domain> SAN and record are created alongside it."
  type        = string
}

variable "target_group_arn" {
  description = "ARN of the EXISTING backend target group (from modules/site) that apex + www should route to."
  type        = string
}

variable "https_listener_arn" {
  description = "ARN of the shared ALB HTTPS listener to attach the cert and host-header rule to."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the shared ALB (alias record target)."
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone ID of the shared ALB (needed for the alias records)."
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority for this domain's host-header listener rule. Must be unique across all rules on the shared listener."
  type        = number
}

variable "spf_txt" {
  description = "Optional apex SPF TXT record value (e.g. \"v=spf1 -all\" for no mail, or \"v=spf1 include:spf.messagingengine.com -all\" for Fastmail). Empty string skips the record."
  type        = string
  default     = ""
}

variable "apex_txt_extra" {
  description = "Additional apex TXT strings published alongside spf_txt in the SINGLE apex TXT record set — e.g. [\"google-site-verification=...\"]. Route 53 allows only one TXT record set per name, so ownership-verification tokens must share the SPF set rather than being their own record. Empty by default."
  type        = list(string)
  default     = []
}

variable "extra_records" {
  description = "Additional records to create in the apex zone — e.g. mail (MX, DKIM CNAMEs, DMARC, SRV). `name` is a label relative to the zone (\"\" for the apex, or e.g. \"fm1._domainkey\" / \"_dmarc\" / \"_submission._tcp\"); type/ttl/records are standard Route 53. SPF and apex verification tokens live in spf_txt / apex_txt_extra, not here."
  type = list(object({
    name    = string
    type    = string
    ttl     = number
    records = list(string)
  }))
  default = []
}

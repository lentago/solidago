# modules/apex-domain/outputs.tf

output "name_servers" {
  description = "Route 53 nameservers to set at the registrar for this apex domain (the re-delegation step)."
  value       = aws_route53_zone.this.name_servers
}

output "zone_id" {
  description = "Route 53 hosted zone ID for the apex domain."
  value       = aws_route53_zone.this.zone_id
}

output "certificate_arn" {
  description = "ARN of the validated ACM certificate for apex + www."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "url" {
  description = "Public HTTPS URL for the apex domain."
  value       = "https://${var.domain_name}"
}

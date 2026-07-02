# modules/dns/outputs.tf

output "zone_id" {
  description = "Route 53 hosted zone ID (needed for creating DNS records like ALB alias)"
  value       = aws_route53_zone.this.zone_id
}

output "zone_name_servers" {
  description = "Nameservers to configure at your domain registrar (Squarespace)"
  value       = aws_route53_zone.this.name_servers
}

output "certificate_arn" {
  description = "ARN of the validated ACM certificate (needed for ALB HTTPS listener)"
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "domain_name" {
  description = "The domain name this module manages"
  value       = var.domain_name
}
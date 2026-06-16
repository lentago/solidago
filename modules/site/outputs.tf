# modules/site/outputs.tf

output "ecr_repository_url" {
  description = "ECR repository URL the workload repo pushes images to"
  value       = aws_ecr_repository.this.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name (for the deploy workflow's ECR_REPO)"
  value       = aws_ecr_repository.this.name
}

output "service_name" {
  description = "ECS service name (for the deploy workflow's ECS_SERVICE / force-new-deployment)"
  value       = aws_ecs_service.this.name
}

output "target_group_arn" {
  description = "ARN of this site's target group"
  value       = aws_lb_target_group.this.arn
}

output "hostname" {
  description = "Hostname this site answers on"
  value       = var.hostname
}

output "url" {
  description = "Full HTTPS URL for the site"
  value       = "https://${var.hostname}"
}

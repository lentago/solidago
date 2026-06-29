output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "app_subnet_ids" {
  value = module.vpc.app_subnet_ids
}

output "data_subnet_ids" {
  value = module.vpc.data_subnet_ids
}

output "nat_gateway_ips" {
  value = module.vpc.nat_gateway_ips
}
output "kms_key_arn" {
  description = "ARN of the main KMS encryption key"
  value       = module.kms.key_arn
}

output "kms_key_alias" {
  description = "Alias of the main KMS encryption key"
  value       = module.kms.key_alias
}
output "db_credentials_secret_arn" {
  description = "ARN of the database credentials secret"
  value       = module.secrets.db_credentials_secret_arn
}
output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = module.iam.ecs_task_execution_role_arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role"
  value       = module.iam.ecs_task_role_arn
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions OIDC role"
  value       = module.iam.github_actions_role_arn
}

output "github_actions_terraform_role_arn" {
  description = "GitHub Actions Terraform pipeline role ARN for CI/CD"
  value       = module.iam.github_actions_terraform_role_arn
}
output "alb_security_group_id" {
  description = "Security group ID for ALB"
  value       = module.security_groups.alb_security_group_id
}

output "app_security_group_id" {
  description = "Security group ID for app tier"
  value       = module.security_groups.app_security_group_id
}

output "rds_security_group_id" {
  description = "Security group ID for RDS"
  value       = module.security_groups.rds_security_group_id
}

output "redis_security_group_id" {
  description = "Security group ID for Redis"
  value       = module.security_groups.redis_security_group_id
}
# Phase 3 outputs
output "ecr_repository_url" {
  description = "ECR repository URL for pushing container images"
  value       = module.ecr.repository_url
}
output "route53_name_servers" {
  description = "Nameservers to configure at Squarespace for icecreamtofightwith.com"
  value       = module.dns.zone_name_servers
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for ALB HTTPS listener"
  value       = module.dns.certificate_arn
}

output "route53_zone_id" {
  description = "Route 53 hosted zone ID"
  value       = module.dns.zone_id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}
output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = module.ecs.service_name
}

# Phase 4 outputs
output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (hostname:port)"
  value       = module.rds.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL hostname"
  value       = module.rds.address
}

output "rds_db_name" {
  description = "RDS initial database name"
  value       = module.rds.db_name
}

output "rds_master_user_secret_arn" {
  description = "ARN of the RDS-managed master credentials secret"
  value       = module.rds.master_user_secret_arn
}

output "s3_bucket_id" {
  description = "S3 general-purpose bucket name"
  value       = module.s3.bucket_id
}

output "s3_bucket_arn" {
  description = "S3 general-purpose bucket ARN"
  value       = module.s3.bucket_arn
}

output "elasticache_primary_endpoint" {
  description = "ElastiCache Valkey primary endpoint"
  value       = module.elasticache.primary_endpoint_address
}

output "elasticache_port" {
  description = "ElastiCache Valkey port"
  value       = module.elasticache.port
}

# Phase 5 outputs
output "sns_topic_arn" {
  description = "SNS alerting topic ARN"
  value       = module.monitoring.sns_topic_arn
}

output "cloudtrail_arn" {
  description = "CloudTrail trail ARN"
  value       = module.cloudtrail.trail_arn
}

output "config_recorder_name" {
  description = "AWS Config recorder name"
  value       = module.aws_config.recorder_name
}

# Phase 7 outputs
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = module.waf.web_acl_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = module.dashboard.dashboard_name
}
# --- Pitzi Labs landing site (additional site on the shared platform) ---
output "pitzilabs_preview_url" {
  description = "Hidden preview URL for the Pitzi Labs landing site"
  value       = module.site_pitzilabs.url
}

output "pitzilabs_ecr_repository_url" {
  description = "ECR repo the pitzilabs-dev deploy workflow pushes images to"
  value       = module.site_pitzilabs.ecr_repository_url
}

output "pitzilabs_ecs_service_name" {
  description = "ECS service name for the Pitzi Labs landing site"
  value       = module.site_pitzilabs.service_name
}

# --- Lentago Labs landing site (additional site on the shared platform) ---
output "lentago_preview_url" {
  description = "Hidden preview URL for the Lentago Labs landing site"
  value       = module.site_lentago.url
}

output "lentago_ecr_repository_url" {
  description = "ECR repo the lentagolabs-dev deploy workflow pushes images to"
  value       = module.site_lentago.ecr_repository_url
}

output "lentago_ecs_service_name" {
  description = "ECS service name for the Lentago Labs landing site"
  value       = module.site_lentago.service_name
}

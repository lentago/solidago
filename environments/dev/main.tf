terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "foundry"
      ManagedBy   = "terraform"
    }
  }
}
module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  availability_zones = ["us-east-1a", "us-east-1b"]

  # Using defaults for all CIDRs — override here if needed
}
data "aws_caller_identity" "current" {}

module "kms" {
  source = "../../modules/kms"

  environment    = var.environment
  project        = var.project
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = var.aws_region

  service_role_arns = [
    module.iam.ecs_task_execution_role_arn,
    module.iam.ecs_task_role_arn,
  ]
}
module "secrets" {
  source = "../../modules/secrets"

  environment = var.environment
  project     = var.project
  kms_key_arn = module.kms.key_arn
}
module "iam" {
  source = "../../modules/iam"

  environment               = var.environment
  project                   = var.project
  aws_account_id            = data.aws_caller_identity.current.account_id
  aws_region                = var.aws_region
  kms_key_arn               = module.kms.key_arn
  db_credentials_secret_arn = module.secrets.db_credentials_secret_arn
  github_org                = "PitziLabs"
  github_repo               = "foundry-platform-demo" # Terraform pipeline role's OIDC trust
  app_github_repo           = "ice-cream-book"        # App deploy role's OIDC trust (post-#55 split)

  # Additional workload repos that deploy onto this platform via the same app
  # OIDC role. The Pitzi Labs landing site (pitzilabs-dev) and the Lentago Labs
  # landing site (lentagolabs-dev) ride on the shared ALB — see
  # module.site_pitzilabs / module.site_lentago below. The role's ECR/ECS
  # permissions are already account-scoped, so this trust entry is all that's
  # needed.
  additional_app_github_repos = ["pitzilabs-dev", "lentagolabs-dev"]

  # Phase 4: grant ECS roles access to RDS-managed secrets
  rds_managed_secret_access = true
}
module "security_groups" {
  source = "../../modules/security-groups"

  environment = var.environment
  project     = var.project
  vpc_id      = module.vpc.vpc_id
}
# --- Phase 3: Compute & Containers ---
module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment
}

module "dns" {
  source = "../../modules/dns"

  project     = var.project
  environment = var.environment
  domain_name = "icecreamtofightwith.com"

  subject_alternative_names = ["*.icecreamtofightwith.com"]

  create_alb_alias = true
  alb_dns_name     = module.alb.alb_dns_name
  alb_zone_id      = module.alb.alb_zone_id
}
module "alb" {
  source = "../../modules/alb"

  project           = var.project
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  security_group_id = module.security_groups.alb_security_group_id
  certificate_arn   = module.dns.certificate_arn
}
module "ecs" {
  source = "../../modules/ecs"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  app_subnet_ids     = module.vpc.app_subnet_ids
  security_group_id  = module.security_groups.app_security_group_id
  target_group_arn   = module.alb.target_group_arn
  ecr_repository_url = module.ecr.repository_url

  task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn           = module.iam.ecs_task_role_arn

  # aws_ecs_service has an implicit dep on the target group ARN but not on
  # the listener that binds the TG to the ALB. On cold starts where ACM
  # validation delays the HTTPS listener, ECS CreateService races and
  # fails with "target group does not have an associated load balancer".
  # Issue #50. The dep lives here because the ordering is between two
  # sibling modules — the ecs module on its own can't express it.
  depends_on = [module.alb]
}
module "ecs_autoscaling" {
  source = "../../modules/ecs-autoscaling"

  project     = var.project
  environment = var.environment

  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_name = module.ecs.service_name

  min_capacity = 2
  max_capacity = 6
}

# --- Additional site: Pitzi Labs landing (pitzilabs-dev) ---
# Rides on the SHARED ALB + ECS cluster behind a hidden, unguessable subdomain
# of icecreamtofightwith.com (covered by the existing wildcard cert — no new
# cert). Reuses the app security group (already allows ALB->app:8080) and the
# ECS task roles. A host-header listener rule routes only this hostname here;
# everything else still hits the primary app's default action. This is the
# preview surface that gets promoted to pitzilabs.dev later (reuse this module).
module "site_pitzilabs" {
  source = "../../modules/site"

  project     = var.project
  environment = var.environment
  name        = "pitzilabs"
  aws_region  = var.aws_region

  hostname               = var.pitzilabs_preview_host
  listener_rule_priority = 100

  vpc_id            = module.vpc.vpc_id
  app_subnet_ids    = module.vpc.app_subnet_ids
  security_group_id = module.security_groups.app_security_group_id
  ecs_cluster_id    = module.ecs.cluster_id

  https_listener_arn = module.alb.https_listener_arn
  alb_dns_name       = module.alb.alb_dns_name
  alb_zone_id        = module.alb.alb_zone_id
  route53_zone_id    = module.dns.zone_id

  task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn           = module.iam.ecs_task_role_arn

  # Low-traffic preview: one task is plenty.
  desired_count = 1
}

# --- Additional site: Lentago Labs landing (lentagolabs-dev) ---
# The Tidewater (teal+copper+limestone) rebrand of pitzilabs-dev — same
# nginx-on-Fargate static-site shape. Rides on the SHARED ALB + ECS cluster
# behind its own hidden, unguessable subdomain of icecreamtofightwith.com
# (covered by the existing wildcard cert — no new cert). Reuses the app
# security group (already allows ALB->app:8080) and the ECS task roles. A
# host-header listener rule (priority 110, unique vs pitzilabs's 100) routes
# only this hostname here; everything else still hits the primary app's default
# action.
module "site_lentago" {
  source = "../../modules/site"

  project     = var.project
  environment = var.environment
  name        = "lentago"
  aws_region  = var.aws_region

  hostname               = var.lentago_preview_host
  listener_rule_priority = 110

  vpc_id            = module.vpc.vpc_id
  app_subnet_ids    = module.vpc.app_subnet_ids
  security_group_id = module.security_groups.app_security_group_id
  ecs_cluster_id    = module.ecs.cluster_id

  https_listener_arn = module.alb.https_listener_arn
  alb_dns_name       = module.alb.alb_dns_name
  alb_zone_id        = module.alb.alb_zone_id
  route53_zone_id    = module.dns.zone_id

  task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn           = module.iam.ecs_task_role_arn

  # Low-traffic preview: one task is plenty.
  desired_count = 1
}

# --- Phase 4: Data Layer ---
module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  data_subnet_ids       = module.vpc.data_subnet_ids
  rds_security_group_id = module.security_groups.rds_security_group_id
  kms_key_arn           = module.kms.key_arn
}

module "s3" {
  source = "../../modules/s3"

  project     = var.project
  environment = var.environment
  kms_key_arn = module.kms.key_arn

  # Phase 5: Service access for log delivery
  aws_account_id           = data.aws_caller_identity.current.account_id
  enable_cloudtrail_access = true
  cloudtrail_key_prefix    = "cloudtrail"
  enable_config_access     = true
  config_key_prefix        = "config"
}

module "elasticache" {
  source = "../../modules/elasticache"

  project     = var.project
  environment = var.environment

  data_subnet_ids         = module.vpc.data_subnet_ids
  redis_security_group_id = module.security_groups.redis_security_group_id
  kms_key_arn             = module.kms.key_arn
}

# --- Phase 5: Observability ---
module "monitoring" {
  source = "../../modules/monitoring"

  project     = var.project
  environment = var.environment

  alert_email = "cpitzi@gmail.com"

  # ECS dimensions
  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_name = module.ecs.service_name

  # ALB dimensions
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  # RDS dimensions
  rds_instance_id = module.rds.instance_id

  # ElastiCache dimensions
  elasticache_replication_group_id = module.elasticache.replication_group_id
}

module "dashboard" {
  source = "../../modules/dashboard"

  project     = var.project
  environment = var.environment

  ecs_cluster_name                 = module.ecs.cluster_name
  ecs_service_name                 = module.ecs.service_name
  alb_arn_suffix                   = module.alb.alb_arn_suffix
  target_group_arn_suffix          = module.alb.target_group_arn_suffix
  db_instance_identifier           = module.rds.instance_id
  elasticache_replication_group_id = module.elasticache.replication_group_id
  waf_web_acl_name                 = module.waf.web_acl_name
  nat_gateway_ids                  = module.vpc.nat_gateway_ids
}

module "cloudtrail" {
  source = "../../modules/cloudtrail"

  project     = var.project
  environment = var.environment

  s3_bucket_name = module.s3.bucket_id
  kms_key_arn    = module.kms.key_arn
}

module "aws_config" {
  source = "../../modules/aws-config"

  project     = var.project
  environment = var.environment

  s3_bucket_name = module.s3.bucket_id
  s3_key_prefix  = "config"
  sns_topic_arn  = module.monitoring.sns_topic_arn
}

module "budgets" {
  source = "../../modules/budgets"

  project               = var.project
  environment           = var.environment
  monthly_budget_amount = "100"
  sns_topic_arn         = module.monitoring.sns_topic_arn
}

# --- Phase 7: Security Hardening ---
module "waf" {
  source = "../../modules/waf"

  project     = var.project
  environment = var.environment
  alb_arn     = module.alb.alb_arn
}

moved {
  from = module.cloudtrail.aws_s3_bucket_policy.cloudtrail
  to   = module.s3.aws_s3_bucket_policy.this[0]
}

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Packaging the ALB-log shipper Lambda: archive_file zips the vendored
    # betula package; the external data source runs the pinned-ref fetch at plan
    # time (see modules/alb-log-shipper).
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "solidago"
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

# Dedicated CMK that encrypts the Terraform state bucket. Created outside
# Terraform by scripts/bootstrap/bootstrap-backend.sh (see backend.tf), so we
# look it up by alias rather than manage it here. Its ARN is handed to the IAM
# module so the GitHub Actions roles can read/write the KMS-encrypted state.
data "aws_kms_alias" "tfstate" {
  name = "alias/solidago-tfstate"
}

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
  tfstate_kms_key_arn       = data.aws_kms_alias.tfstate.target_key_arn
  db_credentials_secret_arn = module.secrets.db_credentials_secret_arn
  github_org                = "lentago"
  github_repo               = "solidago"       # Terraform pipeline role's OIDC trust
  app_github_repo           = "ice-cream-book" # App deploy role's OIDC trust (post-#55 split)

  # Additional workload repos that deploy onto this platform via the same app
  # OIDC role. The site repos were renamed 2026-07-04 to the site-<domain>
  # convention (ice-cream-book → site-icecreamtofightwith-com, lentagolabs-dev
  # → site-lentago-dev); both old and new names are trusted during the
  # transition — prune the old names (and flip app_github_repo above) once the
  # renamed repos' deploys are proven green. The pitzilabs-dev / site-pitzilabs-dev
  # trust was removed 2026-07-10 (#80) when the retired Pitzi Labs preview site
  # was torn down. The sites ride on the shared ALB — see module.site_lentago
  # below. The role's ECR/ECS permissions are already account-scoped, so this
  # trust entry is all that's needed.
  additional_app_github_repos = [
    "lentagolabs-dev",
    "site-icecreamtofightwith-com",
    "site-lentago-dev",
    # Essex Crossing HOA wiki (pondviewlane.com content) — deploys the built
    # Astro site to module.site_pondview below as a hidden, unlisted preview for
    # trustee review before any public launch. Private repo; only the rendered
    # site is served. Owner-qualified because this one lives outside the org, on
    # the maintainer's personal account (cpitzi), not under lentago.
    "cpitzi/essex-crossing-hoa",
  ]

  # Phase 4: grant ECS roles access to RDS-managed secrets
  rds_managed_secret_access = true

  # Observability fabric Phase 2: the execution role reads the FireLens ->
  # Axiom ingest header at container start.
  additional_execution_secret_arns = [module.secrets.axiom_ingest_secret_arn]
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

  # Deliver per-request access logs to a dedicated S3 bucket — the visitor-
  # source signal (client IP, referer, user-agent) for betula -> Axiom.
  enable_access_logs = true
}

# --- ALB access-log -> Axiom shipper (visitor-source telemetry) ---
# The deployment half of the pipeline module.alb opened above (#108, closing the
# loop on #106/#107). Packages betula's reusable S3->Axiom shipper
# (lentago/betula clients/aws/alb-logs/alb_shipper, pinned) as a Lambda and
# triggers it on ObjectCreated in the access-logs bucket. betula owns the
# shipper code; this repo owns the AWS moving parts (Lambda, IAM, notification),
# mirroring how it owns the ECS FireLens sidecars for the ECS emitter.
module "alb_log_shipper" {
  source = "../../modules/alb-log-shipper"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  access_logs_bucket = module.alb.access_logs_bucket
  access_logs_prefix = module.alb.access_logs_prefix

  # Parallel to the ECS FireLens dataset (cjp-solidago-ecs); a distinct
  # dataset for the S3-based ALB access-log source. The token is the BARE
  # form the Python shipper expects (see modules/secrets), not the FireLens
  # header form used by module.ecs.
  axiom_dataset          = "cjp-solidago-alb"
  axiom_token_secret_arn = module.secrets.axiom_alb_ingest_secret_arn

  # The module resolves the token by reading the secret's current *version*
  # (aws_secretsmanager_secret_version) to inject it into the Lambda env. The
  # ARN input alone only orders against the secret shell, so gate the whole
  # module on module.secrets to guarantee the placeholder version exists first.
  depends_on = [module.secrets]
}
module "ecs" {
  source = "../../modules/ecs"

  # Observability fabric Phase 2: container logs -> Axiom via FireLens
  # (betula archive plane; one shared dataset, services distinguished by the
  # ecs metadata FireLens stamps on every event).
  axiom_dataset          = "cjp-solidago-ecs"
  axiom_token_secret_arn = module.secrets.axiom_ingest_secret_arn

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

# --- Additional site: Lentago Labs landing (lentagolabs-dev) ---
# The Tidewater (teal+copper+limestone) rebrand of the retired pitzilabs-dev —
# same nginx-on-Fargate static-site shape. Rides on the SHARED ALB + ECS cluster
# behind its own hidden, unguessable subdomain of icecreamtofightwith.com
# (covered by the existing wildcard cert — no new cert). Reuses the app
# security group (already allows ALB->app:8080) and the ECS task roles. A
# host-header listener rule (priority 110) routes only this hostname here;
# everything else still hits the primary app's default action. (Priority 100 is
# now free — it belonged to the torn-down site_pitzilabs preview, #80.)
module "site_lentago" {
  source = "../../modules/site"

  # Observability fabric Phase 2: container logs -> Axiom via FireLens
  # (betula archive plane; one shared dataset, services distinguished by the
  # ecs metadata FireLens stamps on every event).
  axiom_dataset          = "cjp-solidago-ecs"
  axiom_token_secret_arn = module.secrets.axiom_ingest_secret_arn

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

  # Promoted to its own apex domain (lentago.dev) via module.lentago_domain
  # below, so the hidden preview DNS record is retired. The host-header rule
  # stays to keep the target group ALB-associated (the ECS service depends on
  # it; it can't depend on the apex-domain rule without a module cycle).
  create_dns_record = false

  # Low-traffic preview: one task is plenty.
  desired_count = 1
}

# --- Promote lentagolabs-dev to its public apex domain: lentago.dev ---
# Brings the registered apex domain lentago.dev online in front of the EXISTING
# site_lentago backend (target group) on the shared ALB. Its own Route 53 zone +
# ACM cert (apex + www, attached to the shared HTTPS listener via SNI) + a
# host-header rule route lentago.dev / www.lentago.dev to that target group.
# Two-phase apply: `terraform apply
# -target=module.lentago_domain.aws_route53_zone.this` first, re-delegate the NS
# at the registrar (Squarespace), then a full apply — otherwise ACM DNS
# validation hangs until the delegation is live. See the module header.
module "lentago_domain" {
  source = "../../modules/apex-domain"

  project     = var.project
  environment = var.environment
  name        = "lentago"
  domain_name = "lentago.dev"

  target_group_arn   = module.site_lentago.target_group_arn
  https_listener_arn = module.alb.https_listener_arn
  alb_dns_name       = module.alb.alb_dns_name
  alb_zone_id        = module.alb.alb_zone_id

  # Unique vs lentago preview (110). (Priority 100 was freed by #80.)
  listener_rule_priority = 120

  # Email is on Fastmail — SPF authorizes Fastmail's senders and hard-fails the
  # rest (lentago.dev sends only via Fastmail).
  spf_txt = "v=spf1 include:spf.messagingengine.com -all"

  # Fastmail mail DNS (MX + DKIM + DMARC). SPF is spf_txt above. SRV client-
  # autodiscovery records can be appended here later from the Fastmail admin.
  extra_records = [
    # Inbound mail
    { name = "", type = "MX", ttl = 300, records = ["10 in1-smtp.messagingengine.com", "20 in2-smtp.messagingengine.com"] },
    # DKIM signing keys (Fastmail publishes the actual keys behind these CNAMEs)
    { name = "fm1._domainkey", type = "CNAME", ttl = 300, records = ["fm1.lentago.dev.dkim.fmhosted.com"] },
    { name = "fm2._domainkey", type = "CNAME", ttl = 300, records = ["fm2.lentago.dev.dkim.fmhosted.com"] },
    { name = "fm3._domainkey", type = "CNAME", ttl = 300, records = ["fm3.lentago.dev.dkim.fmhosted.com"] },
    # DMARC — start in monitor mode (p=none); tighten to quarantine/reject later.
    { name = "_dmarc", type = "TXT", ttl = 300, records = ["v=DMARC1; p=none;"] },
    # GitHub org domain verification for github.com/lentago (proves lentago.dev
    # ownership → "Verified" badge). KEEP — GitHub periodically re-checks; removing
    # this record un-verifies the domain.
    { name = "_gh-lentago-o", type = "TXT", ttl = 300, records = ["0db43759c9"] },
    # GitHub Pages custom-domain verification for lentago.dev (guards against
    # domain takeover on Pages). KEEP — same periodic re-check as the org record.
    { name = "_github-pages-challenge-lentago", type = "TXT", ttl = 300, records = ["9eee8470d3efb8d9b52199a9874d03"] },
  ]
}

# --- Additional site: Essex Crossing HOA wiki (pondviewlane.com content) ---
# A hidden, unlisted preview of the Essex Crossing at Montserrat HOA wiki, for
# the association's trustees to review before any public launch. Same shape as
# module.site_lentago: rides the shared ALB + ECS cluster behind an unguessable
# single-label subdomain of icecreamtofightwith.com (wildcard cert, no new
# cert), reuses the app SG and ECS task roles. create_dns_record stays true —
# unlike site_lentago this one is NOT promoted to an apex domain; the hidden
# preview host IS the delivery surface. Source repo (lentago/essex-crossing-hoa)
# is private; only the built static site is served. Hostname comes from the
# PONDVIEW_PREVIEW_HOST Actions var (out of git), same as the other previews.
module "site_pondview" {
  source = "../../modules/site"

  # Observability fabric Phase 2: container logs -> Axiom via FireLens, same
  # shared dataset as the other sites (distinguished by ECS metadata).
  axiom_dataset          = "cjp-solidago-ecs"
  axiom_token_secret_arn = module.secrets.axiom_ingest_secret_arn

  project     = var.project
  environment = var.environment
  name        = "pondview"
  aws_region  = var.aws_region

  hostname               = var.pondview_preview_host
  listener_rule_priority = 130

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

module "grafana_cloud" {
  source = "../../modules/grafana-cloud"

  project     = var.project
  environment = var.environment

  grafana_cloud_account_id  = var.grafana_cloud_account_id
  grafana_cloud_external_id = var.grafana_cloud_external_id
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

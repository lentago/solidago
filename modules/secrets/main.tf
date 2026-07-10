# modules/secrets/main.tf

# =============================================================================
# Secrets Manager — Credential Storage Pattern
#
# This establishes the pattern we'll use for all application secrets.
# Right now it's a placeholder; in Phase 4, we'll create a secret for
# RDS credentials (either manually or via RDS's native Secrets Manager
# integration). The important thing is the encryption and access pattern
# is already in place.
#
# Why Secrets Manager over SSM Parameter Store (SecureString)?
# - Native secret rotation support (Lambda-backed)
# - Cross-account sharing capabilities  
# - RDS, Redshift, and DocumentDB have built-in rotation integrations
# - JSON secret values (store username + password + host in one secret)
# SSM Parameter Store is cheaper ($0 vs $0.40/secret/month) but lacks
# the rotation machinery. For a lab demonstrating production patterns,
# Secrets Manager is the right choice.
# =============================================================================

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.project}-${var.environment}/db-credentials"
  description = "Database credentials for the application (placeholder until Phase 4)"
  kms_key_id  = var.kms_key_arn

  # Secrets Manager has a gotcha: deleted secrets retain their name for the
  # recovery window period. If you terraform destroy and then re-create,
  # you'll get a "already scheduled for deletion" error. A shorter window
  # helps in a lab. Minimum is 7 days; 0 means force-delete immediately.
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project}-${var.environment}-db-credentials"
  }
}

# The secret "version" holds the actual value. Separating the secret
# (the container) from the secret version (the value) is a Secrets Manager
# concept that enables rotation — new versions get created while old ones
# are still readable during the rotation window.
resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  # Placeholder JSON structure matching what RDS will eventually need.
  # Using jsonencode keeps it clean. In Phase 4, we'll either:
  # (a) update this with real credentials, or
  # (b) let RDS manage the secret directly and import it.
  secret_string = jsonencode({
    username = "placeholder"
    password = "placeholder"
    host     = "placeholder"
    port     = 5432
    dbname   = "placeholder"
  })

  # We don't want Terraform to fight us when the secret value changes
  # outside of Terraform (e.g., via rotation or manual update).
  lifecycle {
    ignore_changes = [secret_string]
  }
}
# --- Axiom ingest header (observability fabric Phase 2) ---
# Holds the Fluent Bit HTTP-output header line FireLens injects when shipping
# ECS container logs to Axiom (betula's archive plane). The value is set
# out-of-band (never via Terraform) and MUST be the literal string:
#   Authorization Bearer <axiom-ingest-token>
# (space-separated Fluent Bit header syntax — no colon after "Authorization").
# The token is an Axiom ingest-only token scoped to the cjp-solidago-ecs
# dataset. Rotation = put a new secret value, then force a new deployment.
resource "aws_secretsmanager_secret" "axiom_ingest" {
  name        = "${var.project}-${var.environment}-axiom-ingest-header"
  description = "Fluent Bit header line for FireLens -> Axiom log shipping (Authorization Bearer <ingest token>)"
  kms_key_id  = var.kms_key_arn

  tags = {
    Name = "${var.project}-${var.environment}-axiom-ingest-header"
  }
}

resource "aws_secretsmanager_secret_version" "axiom_ingest" {
  secret_id     = aws_secretsmanager_secret.axiom_ingest.id
  secret_string = "PLACEHOLDER-set-out-of-band"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# --- Axiom ALB access-log ingest token (visitor-source telemetry) ---
# Feeds the S3 -> Axiom Lambda shipper (module.alb_log_shipper, solidago#108)
# that ships ALB access logs to the cjp-solidago-alb dataset.
#
# IMPORTANT — this stores a BARE token, NOT the "Authorization Bearer <token>"
# header form of axiom_ingest above. That sibling holds the Fluent Bit header
# string verbatim because FireLens needs it as-is. betula's Python shipper
# (clients/aws/alb-logs/alb_shipper/axiom.py) instead reads a BARE token from
# the AXIOM_API_TOKEN env var and builds the "Bearer <token>" header itself, so
# storing the header form here would produce a broken double-"Bearer" header.
# The "-header" name suffix mirrors the sibling for discoverability only.
#
# Ingest-only token scoped to cjp-solidago-alb. Set out-of-band; never via
# Terraform (the version below is a placeholder, and secret_string is ignored).
resource "aws_secretsmanager_secret" "axiom_alb_ingest" {
  name        = "${var.project}-${var.environment}-axiom-alb-ingest-header"
  description = "BARE Axiom ingest token for the ALB access-log -> Axiom Lambda shipper (cjp-solidago-alb dataset). Not the Fluent Bit header form."
  kms_key_id  = var.kms_key_arn

  tags = {
    Name = "${var.project}-${var.environment}-axiom-alb-ingest-header"
  }
}

resource "aws_secretsmanager_secret_version" "axiom_alb_ingest" {
  secret_id     = aws_secretsmanager_secret.axiom_alb_ingest.id
  secret_string = "PLACEHOLDER-set-out-of-band"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

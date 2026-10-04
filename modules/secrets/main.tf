# modules/secrets/main.tf

# =============================================================================
# Secrets Manager — Credential Storage Pattern
#
# This established the pattern used for all application secrets (Axiom
# ingest headers below reuse it). It was originally a placeholder intended
# to hold RDS credentials once Phase 4 landed.
#
# STATUS: unused / orphaned. Phase 4 (modules/rds) chose RDS-managed master
# passwords instead (Decision #19, docs/reference-notes.md) — RDS creates
# and rotates its own `rds!db-...` secret, so this secret's placeholder
# value is never read by anything and no live credentials are ever written
# to it. It is still provisioned and still IAM-readable (modules/iam grants
# both ECS roles GetSecretValue on it), but nothing in this repo references
# it via `valueFrom` or otherwise consumes it. Disposition (leave vs.
# repurpose vs. remove) is tracked in issue #20; this comment only documents
# the current state, not a decision.
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
  description = "Unused placeholder — RDS uses its own managed master password (Decision #19). See issue #20."
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

  # Placeholder JSON structure that was meant to match what RDS would need.
  # Phase 4 went a different way: RDS manages its own master-password secret
  # (manage_master_user_password = true, modules/rds), so this value was
  # never updated with real credentials and stays a placeholder — see the
  # STATUS note above.
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
  count = var.axiom_enabled ? 1 : 0

  name        = "${var.project}-${var.environment}-axiom-ingest-header"
  description = "Fluent Bit header line for FireLens -> Axiom log shipping (Authorization Bearer <ingest token>)"
  kms_key_id  = var.kms_key_arn

  tags = {
    Name = "${var.project}-${var.environment}-axiom-ingest-header"
  }
}

resource "aws_secretsmanager_secret_version" "axiom_ingest" {
  count = var.axiom_enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.axiom_ingest[0].id
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
  count = var.axiom_enabled ? 1 : 0

  name        = "${var.project}-${var.environment}-axiom-alb-ingest-header"
  description = "BARE Axiom ingest token for the ALB access-log -> Axiom Lambda shipper (cjp-solidago-alb dataset). Not the Fluent Bit header form."
  kms_key_id  = var.kms_key_arn

  tags = {
    Name = "${var.project}-${var.environment}-axiom-alb-ingest-header"
  }
}

resource "aws_secretsmanager_secret_version" "axiom_alb_ingest" {
  count = var.axiom_enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.axiom_alb_ingest[0].id
  secret_string = "PLACEHOLDER-set-out-of-band"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Adding count to the Axiom secrets (#188) shifted their addresses to [0].
# Tell Terraform they moved rather than destroy+recreate the live secrets
# (whose out-of-band values Terraform never holds).
moved {
  from = aws_secretsmanager_secret.axiom_ingest
  to   = aws_secretsmanager_secret.axiom_ingest[0]
}

moved {
  from = aws_secretsmanager_secret_version.axiom_ingest
  to   = aws_secretsmanager_secret_version.axiom_ingest[0]
}

moved {
  from = aws_secretsmanager_secret.axiom_alb_ingest
  to   = aws_secretsmanager_secret.axiom_alb_ingest[0]
}

moved {
  from = aws_secretsmanager_secret_version.axiom_alb_ingest
  to   = aws_secretsmanager_secret_version.axiom_alb_ingest[0]
}

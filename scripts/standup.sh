#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# standup.sh — bring the solidago-dev platform back after a selective teardown.
#
# Reverses scripts/teardown.sh: starts the RDS instance (if it was stopped) and
# runs a FULL `terraform apply` to reconcile every ephemeral resource — and the
# cheap cascade dependents (dashboard, alarms, WAF association, Route 53 alias /
# listener rules) — back to the committed configuration, in dependency order.
# See docs/RUNBOOK.md for the full procedure.
#
# WHY A FULL APPLY (not `-target`): the durable foundation is untouched, so a
# no-target apply is a no-op for everything that survived and recreates exactly
# what teardown removed — including the cascade dependents a targeted apply
# would miss. Terraform orders the graph correctly on its own.
#
# ORDER / KNOWN CONSTRAINTS encoded here (see docs/RUNBOOK.md):
#   (a) The Route 53 hosted zone must exist AND be delegated at the registrar
#       BEFORE ACM certificate validation, or validation hangs ~75 min. In a
#       selective standup the zone + cert are KEPT, so a single apply is safe;
#       this script hard-checks that the zone is still in state and aborts with
#       two-phase instructions if it is not.
#   (b) ECR repositories are KEPT by teardown, so images survive and sites come
#       back serving. If the ECR repos were ever emptied/recreated, each
#       workload repo's Build & Deploy must be re-run or the sites 503.
#
# Usage:
#   scripts/standup.sh [-y|--yes] [--wait]
#
# Environment:
#   AUTO_APPROVE=1          skip confirmation and pass -auto-approve (same as -y)
#   RDS_WAIT=1              wait for RDS to be 'available' before applying (--wait)
#   AWS_PROFILE / AWS_REGION honoured via the standard AWS credential chain
#   TF_VAR_lentago_preview_host  REQUIRED
#     (mirrors the CI Actions variable)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${REPO_ROOT}/environments/dev"

PROJECT="solidago"
ENVIRONMENT="dev"
AWS_REGION="${AWS_REGION:-us-east-1}"
RDS_IDENTIFIER="${PROJECT}-${ENVIRONMENT}-postgres"

AUTO_APPROVE="${AUTO_APPROVE:-}"
RDS_WAIT="${RDS_WAIT:-}"
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) AUTO_APPROVE=1 ;;
    --wait) RDS_WAIT=1 ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: unknown argument '${arg}' (try --help)" >&2; exit 2 ;;
  esac
done

# --- Preflight -------------------------------------------------------------
echo "==> Preflight checks..."

if ! command -v terraform >/dev/null 2>&1; then
  echo "ERROR: terraform not found on PATH." >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found on PATH." >&2
  exit 1
fi

if [[ -z "${TF_VAR_lentago_preview_host:-}" ]]; then
  echo "ERROR: TF_VAR_lentago_preview_host must be set." >&2
  echo "       This mirrors the repo Actions variable LENTAGO_PREVIEW_HOST." >&2
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: unable to authenticate to AWS. Check your credentials/AWS_PROFILE." >&2
  exit 1
fi

# Terraform must already be initialised against the S3 backend.
if [[ ! -d "${ENV_DIR}/.terraform" ]]; then
  echo "==> .terraform not found — running 'terraform init'..."
  terraform -chdir="${ENV_DIR}" init
fi

# Constraint (a): the hosted zone must survive teardown. If it does not, a full
# apply would trigger fresh ACM validation that hangs until the new nameservers
# are re-delegated at the registrar. Refuse to proceed blindly.
echo "==> Verifying the Route 53 hosted zone is still in state (constraint a)..."
if ! terraform -chdir="${ENV_DIR}" state list 2>/dev/null | grep -q '^module\.dns\.aws_route53_zone\.main$'; then
  echo "ERROR: module.dns.aws_route53_zone.main is NOT in state." >&2
  echo "       A full apply now would create a NEW zone with NEW nameservers and" >&2
  echo "       ACM validation would hang (~75 min) until you re-delegate at the" >&2
  echo "       registrar. Follow the TWO-PHASE STANDUP in docs/RUNBOOK.md:" >&2
  echo "         1. terraform apply -target=module.dns.aws_route53_zone.main" >&2
  echo "         2. re-delegate the NS records at your registrar" >&2
  echo "         3. re-run scripts/standup.sh" >&2
  exit 1
fi

# --- RDS handling ----------------------------------------------------------
echo "==> Checking RDS instance ${RDS_IDENTIFIER}..."
RDS_STATUS="$(aws rds describe-db-instances \
  --db-instance-identifier "${RDS_IDENTIFIER}" \
  --region "${AWS_REGION}" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "not-found")"
case "${RDS_STATUS}" in
  stopped)
    echo "    Instance is stopped — starting it..."
    aws rds start-db-instance \
      --db-instance-identifier "${RDS_IDENTIFIER}" \
      --region "${AWS_REGION}" >/dev/null
    if [[ -n "${RDS_WAIT}" ]]; then
      echo "    Waiting for RDS to become available (this can take several minutes)..."
      aws rds wait db-instance-available \
        --db-instance-identifier "${RDS_IDENTIFIER}" \
        --region "${AWS_REGION}"
      echo "    RDS is available."
    else
      echo "    Start initiated (takes a few minutes). Pass --wait to block on it."
    fi
    ;;
  available|starting)
    echo "    Instance is ${RDS_STATUS} — nothing to do."
    ;;
  not-found)
    echo "    Instance not found — it was destroyed (RDS_MODE=destroy)."
    echo "    terraform apply will recreate it (empty database)."
    ;;
  *)
    echo "    Instance is '${RDS_STATUS}' — leaving as-is; apply will reconcile." >&2
    ;;
esac

# --- Terraform apply (full reconcile) --------------------------------------
echo ""
echo "==> Bringing the environment back with a full terraform apply..."
if [[ -z "${AUTO_APPROVE}" ]]; then
  terraform -chdir="${ENV_DIR}" apply
else
  terraform -chdir="${ENV_DIR}" apply -auto-approve
fi

echo ""
echo "==> Standup complete."
echo "    ECR repositories were preserved, so the sites should serve immediately."
echo "    If any site returns 503, its ECR repo is empty — re-run that workload"
echo "    repo's Build & Deploy workflow to re-push the image (constraint b)."

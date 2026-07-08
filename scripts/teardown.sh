#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# teardown.sh — selective, cost-saving teardown of the solidago-dev platform.
#
# Destroys ONLY the expensive, always-on resources that are cheap and fast to
# recreate, while leaving the durable foundation intact. Pair with standup.sh
# to bring the environment back. See docs/RUNBOOK.md for the full procedure and
# the reasoning behind every classification.
#
# EPHEMERAL — torn down here (the daily cost drivers):
#   - NAT Gateways + their EIPs        (module.vpc.aws_nat_gateway/aws_eip.nat)
#   - Application Load Balancer         (module.alb)
#   - Primary app ECS service/tasks     (module.ecs.aws_ecs_service.app)
#   - Preview-site ECS services/tasks   (module.site_*.aws_ecs_service.this)
#   - ElastiCache replication group     (module.elasticache...replication_group)
#   - RDS instance                      (STOPPED by default; destroyed only
#                                        with RDS_MODE=destroy)
#
# KEEP — never touched by this script (the durable foundation):
#   - S3 state bucket + its bootstrap-managed KMS CMK (alias/foundry-tfstate)
#   - IAM roles / OIDC provider         (module.iam)
#   - ECR repositories + images         (module.ecr, module.site_*'s ECR repos)
#   - Route 53 hosted zone + ACM cert   (module.dns zone/cert; NS delegation)
#   - Terraform-managed KMS key         (module.kms, alias/solidago-dev-main)
#   - Secrets Manager secrets           (module.secrets)
#   - Security groups, VPC core, CloudWatch log groups
#
# CASCADE NOTE: `terraform destroy -target` also destroys resources that DEPEND
# on the targets — the CloudWatch dashboard, ALB/ECS/RDS/cache alarms, the WAF
# <-> ALB association, and the Route 53 alias / listener-rule records. These are
# free and are faithfully recreated by standup.sh's full apply. That is expected.
#
# WHY RDS IS STOPPED, NOT DESTROYED (default): stopping preserves the data,
# saves the instance-hour charge (the bulk of RDS cost), and sidesteps the
# KMS-secret re-key trap from issue #20 (a destroyed+recreated db-credentials
# secret can come back on a delete-scheduled key). AWS auto-starts a stopped
# instance after 7 days — for longer idles, or to reclaim storage cost, use
# RDS_MODE=destroy (which loses data: skip_final_snapshot = true).
#
# Usage:
#   scripts/teardown.sh [-y|--yes]
#
# Environment:
#   RDS_MODE=stop|destroy   RDS handling (default: stop)
#   AUTO_APPROVE=1          skip the interactive confirmation (same as -y)
#   AWS_PROFILE / AWS_REGION honoured via the standard AWS credential chain
#   TF_VAR_pitzilabs_preview_host / TF_VAR_lentago_preview_host  REQUIRED
#     (mirror the CI Actions variables; Terraform needs them even to destroy)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${REPO_ROOT}/environments/dev"

PROJECT="solidago"
ENVIRONMENT="dev"
AWS_REGION="${AWS_REGION:-us-east-1}"
RDS_MODE="${RDS_MODE:-stop}"
RDS_IDENTIFIER="${PROJECT}-${ENVIRONMENT}-postgres"

AUTO_APPROVE="${AUTO_APPROVE:-}"
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) AUTO_APPROVE=1 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: unknown argument '${arg}' (try --help)" >&2; exit 2 ;;
  esac
done

# Ephemeral targets destroyed in a single `terraform destroy` invocation.
# Terraform computes the correct order and pulls in dependents automatically.
# NOTE: the site services are targeted at the RESOURCE level, never the whole
# module — module.site_* own ECR repositories we must NOT delete (constraint b).
EPHEMERAL_TARGETS=(
  "module.ecs.aws_ecs_service.app"
  "module.site_pitzilabs.aws_ecs_service.this"
  "module.site_lentago.aws_ecs_service.this"
  "module.alb"
  "module.elasticache.aws_elasticache_replication_group.this"
  "module.vpc.aws_nat_gateway.main"
  "module.vpc.aws_eip.nat"
)

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

case "${RDS_MODE}" in
  stop|destroy) ;;
  *) echo "ERROR: RDS_MODE must be 'stop' or 'destroy' (got '${RDS_MODE}')." >&2; exit 2 ;;
esac

if [[ -z "${TF_VAR_pitzilabs_preview_host:-}" || -z "${TF_VAR_lentago_preview_host:-}" ]]; then
  echo "ERROR: TF_VAR_pitzilabs_preview_host and TF_VAR_lentago_preview_host must be set." >&2
  echo "       These mirror the repo Actions variables PITZILABS_PREVIEW_HOST /" >&2
  echo "       LENTAGO_PREVIEW_HOST. Terraform requires them even for a targeted destroy." >&2
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: unable to authenticate to AWS. Check your credentials/AWS_PROFILE." >&2
  exit 1
fi

# --- Plan summary + confirmation -------------------------------------------
echo ""
echo "==> Selective teardown of ${PROJECT}-${ENVIRONMENT} (region ${AWS_REGION})"
echo "    The following will be DESTROYED (recreated by standup.sh):"
for t in "${EPHEMERAL_TARGETS[@]}"; do
  echo "      - ${t}"
done
echo "      + cascade dependents: CloudWatch dashboard/alarms, WAF-ALB"
echo "        association, Route 53 alias + preview listener rules"
if [[ "${RDS_MODE}" == "stop" ]]; then
  echo "    RDS ${RDS_IDENTIFIER}: STOPPED (data preserved; auto-starts in 7 days)"
else
  echo "    RDS ${RDS_IDENTIFIER}: DESTROYED (DATA LOSS — skip_final_snapshot = true)"
fi
echo ""
echo "    KEPT: S3 state + bootstrap KMS, IAM/OIDC, ECR (+ images), Route 53"
echo "          zone + ACM cert, Terraform KMS key, Secrets, SGs, VPC core, logs"
echo ""

if [[ -z "${AUTO_APPROVE}" ]]; then
  read -r -p "Proceed with teardown? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# --- RDS handling ----------------------------------------------------------
if [[ "${RDS_MODE}" == "stop" ]]; then
  echo ""
  echo "==> Stopping RDS instance ${RDS_IDENTIFIER}..."
  RDS_STATUS="$(aws rds describe-db-instances \
    --db-instance-identifier "${RDS_IDENTIFIER}" \
    --region "${AWS_REGION}" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null || echo "not-found")"
  case "${RDS_STATUS}" in
    available)
      aws rds stop-db-instance \
        --db-instance-identifier "${RDS_IDENTIFIER}" \
        --region "${AWS_REGION}" >/dev/null
      echo "    Stop initiated (takes a few minutes to reach 'stopped')."
      ;;
    stopped|stopping)
      echo "    Already ${RDS_STATUS} — nothing to do."
      ;;
    not-found)
      echo "    Instance not found — assuming already destroyed. Skipping."
      ;;
    *)
      echo "    Instance is '${RDS_STATUS}'; cannot stop from this state. Skipping." >&2
      ;;
  esac
fi

# --- Terraform destroy (targeted) ------------------------------------------
DESTROY_ARGS=()
for t in "${EPHEMERAL_TARGETS[@]}"; do
  DESTROY_ARGS+=("-target=${t}")
done
if [[ "${RDS_MODE}" == "destroy" ]]; then
  DESTROY_ARGS+=("-target=module.rds.aws_db_instance.main")
fi
if [[ -n "${AUTO_APPROVE}" ]]; then
  DESTROY_ARGS+=("-auto-approve")
fi

echo ""
echo "==> Running targeted terraform destroy..."
terraform -chdir="${ENV_DIR}" destroy "${DESTROY_ARGS[@]}"

echo ""
echo "==> Teardown complete."
echo "    Bring it back with: scripts/standup.sh"
if [[ "${RDS_MODE}" == "stop" ]]; then
  echo "    Reminder: a stopped RDS instance is auto-started by AWS after 7 days."
fi

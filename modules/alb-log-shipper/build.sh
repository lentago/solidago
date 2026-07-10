#!/usr/bin/env bash
# modules/alb-log-shipper/build.sh
#
# Vendor betula's reusable ALB-log shipper package at a PINNED ref so the Lambda
# artifact is reproducible. betula owns the code (lentago/betula
# clients/aws/alb-logs/alb_shipper); solidago never commits a copy of it -- this
# fetches it at build time into build/vendor/alb_shipper/, which Terraform's
# archive_file then zips. The package is standard-library-only (boto3 ships in
# the Lambda runtime), so there is nothing to pip-install.
#
# Env (supplied by the Terraform null_resource that calls this):
#   BETULA_REPO  GitHub owner/repo            (default: lentago/betula)
#   BETULA_REF   pinned commit SHA or tag     (required)
#   VENDOR_DIR   output dir for alb_shipper/  (required)
#
# For a private betula, export a GitHub token as GITHUB_TOKEN (or
# BETULA_GITHUB_TOKEN) so the archive endpoint authorizes; public access needs
# no token.
set -euo pipefail

BETULA_REPO="${BETULA_REPO:-lentago/betula}"
BETULA_REF="${BETULA_REF:?BETULA_REF is required (pin a commit SHA or tag)}"
VENDOR_DIR="${VENDOR_DIR:?VENDOR_DIR is required}"

PKG_PATH="clients/aws/alb-logs/alb_shipper"
TOKEN="${GITHUB_TOKEN:-${BETULA_GITHUB_TOKEN:-}}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "alb-log-shipper: fetching ${BETULA_REPO}@${BETULA_REF} (${PKG_PATH})"

auth=()
if [ -n "$TOKEN" ]; then
  auth=(-H "Authorization: Bearer ${TOKEN}")
fi

# GitHub's repo tarball endpoint resolves any ref (SHA/tag/branch) and, with a
# token, private repos. -L follows the redirect to codeload.
curl -fsSL "${auth[@]}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${BETULA_REPO}/tarball/${BETULA_REF}" \
  | tar -xz -C "$workdir"

src="$(find "$workdir" -type d -path "*/${PKG_PATH}" | head -n1)"
if [ -z "$src" ]; then
  echo "alb-log-shipper: ${PKG_PATH} not found in ${BETULA_REPO}@${BETULA_REF}" >&2
  exit 1
fi

rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
cp -R "$src" "$VENDOR_DIR/alb_shipper"

# Drop any compiled artifacts so the zip is deterministic.
find "$VENDOR_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$VENDOR_DIR" -type f -name '*.pyc' -delete

echo "alb-log-shipper: vendored -> ${VENDOR_DIR}/alb_shipper"

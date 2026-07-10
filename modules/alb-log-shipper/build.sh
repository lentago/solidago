#!/usr/bin/env bash
# modules/alb-log-shipper/build.sh
#
# Vendor betula's reusable ALB-log shipper package at a PINNED ref so the Lambda
# artifact is reproducible. betula owns the code (lentago/betula
# clients/aws/alb-logs/alb_shipper); solidago never commits a copy -- this
# fetches it at build time into build/vendor/alb_shipper/, which Terraform's
# archive_file then zips.
#
# Invoked by the module's `data "external" "build"` at PLAN time, so it follows
# Terraform's external-program protocol: a JSON object arrives on stdin (ignored
# here), the script MUST print a single JSON object on stdout, and all
# human-readable progress goes to stderr. Inputs are positional args:
#
#   $1  BETULA_REF   pinned commit SHA or tag   (required)
#   $2  BETULA_REPO  GitHub owner/repo          (default: lentago/betula)
#
# betula is public, so no token is needed; for a private mirror, export a
# GitHub token as GITHUB_TOKEN (or BETULA_GITHUB_TOKEN) so the archive endpoint
# authorizes.
set -euo pipefail

BETULA_REF="${1:?BETULA_REF is required (pin a commit SHA or tag)}"
BETULA_REPO="${2:-lentago/betula}"

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="${MODULE_DIR}/build/vendor"
PKG_PATH="clients/aws/alb-logs/alb_shipper"
TOKEN="${GITHUB_TOKEN:-${BETULA_GITHUB_TOKEN:-}}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "alb-log-shipper: fetching ${BETULA_REPO}@${BETULA_REF} (${PKG_PATH})" >&2

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

# Drop compiled artifacts, then pin every mtime to the zip epoch floor
# (1980-01-01) so the archive archive_file builds is byte-for-byte identical
# across plans -- the ref is pinned, so only mtimes would otherwise vary and
# churn source_code_hash into a perpetual Lambda diff.
find "$VENDOR_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$VENDOR_DIR" -type f -name '*.pyc' -delete
find "$VENDOR_DIR" -exec touch -t 198001010000 {} +

echo "alb-log-shipper: vendored -> ${VENDOR_DIR}/alb_shipper" >&2

# The sole line of stdout: the external-program result. archive_file zips this
# directory (which contains alb_shipper/), so the handler resolves at the root.
printf '{"vendor_dir":"%s"}\n' "${VENDOR_DIR}"

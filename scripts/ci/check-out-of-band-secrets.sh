#!/usr/bin/env bash
# scripts/ci/check-out-of-band-secrets.sh SLOT [SLOT...]
#
# Post-apply check for SSM SecureString slots whose values are written by hand,
# never by Terraform (#213 pattern, #230). A green apply cannot tell a real
# value from the placeholder a slot was created with, so this fails the run
# when a slot is:
#
#   - missing,
#   - encrypted with an AWS-managed key (aws/ssm), whose key policy lets ANY
#     principal in the account with ssm:GetParameter decrypt it (that includes
#     ReadOnlyAccess roles); slots must use the platform CMK
#     (alias/<project>-<environment>-main), which delegates to IAM, or
#   - empty or still placeholder-shaped (PLACEHOLDER...).
#
# Only the shape is tested. The value is masked in the job log and never
# printed. Called by the apply job of .github/workflows/terraform.yml; the
# apply role's OutOfBandSecretCheck statement (modules/iam) grants the reads.
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 SLOT [SLOT...]" >&2; exit 2; }

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT

# The merge that adds the read grant runs this check straight after its own
# apply, and IAM is eventually consistent: retry an AccessDenied briefly
# before calling it a failure. Any other error fails at once.
aws_retry() {
  local out err attempt
  for attempt in 1 2 3 4 5 6; do
    if out=$("$@" 2>"$errf"); then
      printf '%s' "$out"
      return 0
    fi
    err=$(cat "$errf")
    case "$err" in
      *AccessDenied*) [ "$attempt" -lt 6 ] && { sleep 10; continue; } ;;
    esac
    break
  done
  # Error code and message only; AWS CLI errors never contain the value.
  printf '%s' "$err" | tr '\n' ' ' >&2
  return 1
}

rc=0
for slot in "$@"; do
  if ! key_id=$(aws_retry aws ssm describe-parameters \
      --parameter-filters "Key=Name,Values=$slot" \
      --query 'Parameters[0].KeyId' --output text); then
    echo "::error::Out-of-band secret $slot: could not describe it (see the error above)."
    rc=1; continue
  fi
  if [ "$key_id" = "None" ] || [ -z "$key_id" ]; then
    echo "::error::Out-of-band secret $slot is missing. Create it with aws ssm put-parameter --type SecureString --key-id alias/<project>-<environment>-main (see modules/ask-lambda/main.tf)."
    rc=1; continue
  fi
  # KeyId comes back as whatever the writer passed (alias, key ID or ARN), so
  # ask KMS who manages the key rather than matching the alias string.
  if ! manager=$(aws_retry aws kms describe-key --key-id "$key_id" \
      --query KeyMetadata.KeyManager --output text); then
    echo "::error::Out-of-band secret $slot: could not describe its key $key_id (see the error above)."
    rc=1
  elif [ "$manager" != "CUSTOMER" ]; then
    echo "::error::Out-of-band secret $slot is encrypted with an AWS-managed key ($key_id), which any principal with ssm:GetParameter can decrypt. Rewrite it with --overwrite --key-id alias/<project>-<environment>-main."
    rc=1
  fi
  if ! value=$(aws_retry aws ssm get-parameter --name "$slot" --with-decryption \
      --query Parameter.Value --output text); then
    echo "::error::Out-of-band secret $slot: could not read it (see the error above)."
    rc=1; continue
  fi
  # Mask only inside Actions: elsewhere this line would print the value.
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$value" ]; then
    echo "::add-mask::$value"
  fi
  case "$value" in
    "" | PLACEHOLDER*)
      echo "::error::Out-of-band secret $slot still holds its placeholder. Write the real value with aws ssm put-parameter --overwrite."
      rc=1 ;;
    *) echo "ok: $slot is set and CMK-encrypted (value not shown)" ;;
  esac
  unset value
done
exit "$rc"

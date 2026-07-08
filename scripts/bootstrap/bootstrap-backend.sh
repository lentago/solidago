#!/bin/bash
set -euo pipefail

# Configuration
AWS_PROFILE="foundry"
AWS_REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "${AWS_PROFILE}")
if [[ -z "${ACCOUNT_ID}" ]]; then
  echo "ERROR: Could not determine AWS account ID. Check your AWS_PROFILE." >&2
  exit 1
fi
BUCKET_NAME="solidago-tfstate-${ACCOUNT_ID}"
KMS_ALIAS="alias/solidago-tfstate"

echo "==> Creating S3 bucket for Terraform state..."
aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"

echo "==> Enabling versioning on state bucket..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled \
  --profile "${AWS_PROFILE}"

# ---------------------------------------------------------------------------
# Dedicated customer-managed KMS key (CMK) for the Terraform state bucket.
#
# This is a SEPARATE key from the Terraform-managed CMK (alias/solidago-dev-main
# in modules/kms). That separation is deliberate:
#   1. Chicken-and-egg — the state bucket must exist and be encryptable BEFORE
#      Terraform can run, so its key can't be a Terraform-managed resource.
#   2. Circular dependency — the Terraform key is defined in the state that
#      lives in this bucket. Encrypting the bucket with it would make the key
#      depend on a state file that can only be read using that key.
#   3. Destroy safety — `terraform destroy` schedules the Terraform-managed key
#      for deletion (30-day window). If that key encrypted the state bucket,
#      a routine teardown would lock you out of your own state. This dedicated
#      key is never touched by Terraform, so it is never scheduled for deletion.
#
# Key policy is intentionally minimal: it grants the account root full access
# (the standard KMS "escape hatch"), which lets IAM policies authorize the
# actual principals. The Terraform pipeline and app-deploy IAM roles get
# scoped kms:Encrypt/Decrypt/GenerateDataKey/DescribeKey via modules/iam —
# the same two-lock (key policy + IAM) pattern the rest of the platform uses.
# We grant via IAM rather than in the key policy because these roles don't
# exist yet at bootstrap time.
# ---------------------------------------------------------------------------
echo "==> Ensuring dedicated KMS CMK for state bucket encryption..."
KEY_ID=$(aws kms describe-key \
  --key-id "${KMS_ALIAS}" \
  --query 'KeyMetadata.KeyId' \
  --output text \
  --profile "${AWS_PROFILE}" 2>/dev/null || true)

if [[ -z "${KEY_ID}" || "${KEY_ID}" == "None" ]]; then
  echo "    No existing key found — creating a new CMK..."
  KEY_ID=$(aws kms create-key \
    --description "foundry Terraform state bucket encryption key" \
    --tags TagKey=Name,TagValue=solidago-tfstate-key \
    --policy '{
      "Version": "2012-10-17",
      "Id": "solidago-tfstate-key-policy",
      "Statement": [
        {
          "Sid": "EnableRootAccountAccess",
          "Effect": "Allow",
          "Principal": { "AWS": "arn:aws:iam::'"${ACCOUNT_ID}"':root" },
          "Action": "kms:*",
          "Resource": "*"
        }
      ]
    }' \
    --query 'KeyMetadata.KeyId' \
    --output text \
    --profile "${AWS_PROFILE}")

  echo "    Enabling automatic annual key rotation..."
  aws kms enable-key-rotation \
    --key-id "${KEY_ID}" \
    --profile "${AWS_PROFILE}"

  echo "    Creating alias ${KMS_ALIAS}..."
  aws kms create-alias \
    --alias-name "${KMS_ALIAS}" \
    --target-key-id "${KEY_ID}" \
    --profile "${AWS_PROFILE}"
else
  echo "    Reusing existing key ${KEY_ID} (alias ${KMS_ALIAS})."
fi

KEY_ARN=$(aws kms describe-key \
  --key-id "${KEY_ID}" \
  --query 'KeyMetadata.Arn' \
  --output text \
  --profile "${AWS_PROFILE}")

echo "==> Enabling server-side encryption (SSE-KMS with the dedicated CMK)..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms",
          "KMSMasterKeyID": "'"${KEY_ARN}"'"
        },
        "BucketKeyEnabled": true
      }
    ]
  }' \
  --profile "${AWS_PROFILE}"

echo "==> Blocking all public access on state bucket..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
  --profile "${AWS_PROFILE}"

echo ""
echo "==> Bootstrap complete!"
echo "    State bucket: ${BUCKET_NAME}"
echo "    Region:       ${AWS_REGION}"
echo "    Encryption:   SSE-KMS (${KMS_ALIAS})"
echo "    Key ARN:      ${KEY_ARN}"
echo "    Locking:      S3-native (use_lockfile = true)"
echo ""
echo "    NOTE: If you are upgrading an EXISTING backend from AES256, run"
echo "          'terraform init -reconfigure' in environments/dev after this."

# modules/s3/main.tf
# -------------------------------------------------------------------
# General-purpose S3 bucket with production security defaults.
#
# Modern Terraform S3 pattern: the bucket itself is a bare resource,
# and all configuration (versioning, encryption, access controls,
# lifecycle) is managed through separate companion resources. This
# is the AWS provider v4+ approach — inline configuration blocks on
# aws_s3_bucket are deprecated and will eventually be removed.
#
# Resources created:
#   1. aws_s3_bucket               — the bucket itself
#   2. aws_s3_bucket_versioning    — object version history
#   3. aws_s3_bucket_server_side_encryption_configuration — KMS encryption
#   4. aws_s3_bucket_public_access_block — all four "block public" settings
#   5. aws_s3_bucket_lifecycle_configuration — log rotation + version cleanup
# -------------------------------------------------------------------

# --- The bucket ---
# force_destroy = true in this environment so terraform destroy doesn't fail on
# non-empty buckets. In prod you'd set this to false.
resource "aws_s3_bucket" "this" {
  bucket        = "${var.project}-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy

  tags = {
    Name = "${var.project}-${var.environment}-bucket"
  }
}

# We need the account ID for globally unique bucket naming
data "aws_caller_identity" "current" {}

# --- Versioning ---
# Protects against accidental deletes and overwrites. Every PUT
# creates a new version; DELETE just adds a delete marker. You can
# always recover previous versions.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --- Encryption ---
# SSE-KMS with our CMK. bucket_key_enabled reduces KMS API calls
# (and cost) by generating a bucket-level key that encrypts objects
# instead of calling KMS for every individual object.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# --- Public access block ---
# All four settings enabled = absolutely no public access possible.
# This is defense-in-depth: even if someone accidentally attaches a
# public bucket policy, S3 will reject it.
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Lifecycle rules ---
# Two rules:
#   1. Clean up noncurrent versions after N days (prevents version
#      history from growing unbounded and costing money).
#   2. Expire objects under the logs/ prefix after N days (log rotation).
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Depends on versioning being enabled first
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "cleanup-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    # Also clean up incomplete multipart uploads after 7 days.
    # These are fragments from failed large-file uploads that
    # silently accumulate and cost money.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    expiration {
      days = var.log_expiration_days
    }
  }
}

# --- Service access bucket policy ---
# Conditionally created when CloudTrail and/or Config need write access.
# Both services require explicit S3 bucket policies because they operate
# as service principals, not IAM roles you control.
#
# This policy lives in the S3 module (not in the consumer modules) because
# AWS only allows ONE bucket policy per bucket. If CloudTrail and Config
# each tried to create their own aws_s3_bucket_policy, the last one would
# overwrite the first. Centralizing here avoids that conflict.

locals {
  # Build the policy only when at least one service needs access
  needs_bucket_policy = var.enable_cloudtrail_access || var.enable_config_access
}

data "aws_iam_policy_document" "service_access" {
  count = local.needs_bucket_policy ? 1 : 0

  # --- CloudTrail statements ---
  dynamic "statement" {
    for_each = var.enable_cloudtrail_access ? [1] : []
    content {
      sid    = "AWSCloudTrailAclCheck"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }

      actions   = ["s3:GetBucketAcl"]
      resources = [aws_s3_bucket.this.arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_cloudtrail_access ? [1] : []
    content {
      sid    = "AWSCloudTrailWrite"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }

      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/${var.cloudtrail_key_prefix}/AWSLogs/${var.aws_account_id}/*"]

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
    }
  }

  # --- AWS Config statements ---
  dynamic "statement" {
    for_each = var.enable_config_access ? [1] : []
    content {
      sid    = "AWSConfigAclCheck"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }

      actions   = ["s3:GetBucketAcl"]
      resources = [aws_s3_bucket.this.arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_config_access ? [1] : []
    content {
      sid    = "AWSConfigWrite"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }

      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/${var.config_key_prefix}/AWSLogs/${var.aws_account_id}/Config/*"]

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  count  = local.needs_bucket_policy ? 1 : 0
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.service_access[0].json
}

# modules/cloudtrail/main.tf
# =============================================================================
# CLOUDTRAIL: API AUDIT LOGGING
#
# This module creates:
#   1. A CloudTrail trail capturing all management events
#
# Every API call in the account is recorded — console clicks, CLI commands,
# SDK calls, and service-to-service actions. Logs are encrypted with your
# CMK and delivered to the existing S3 bucket under a "cloudtrail/" prefix.
#
# Key design choices:
#   - is_multi_region_trail = true: captures events from ALL regions, not
#     just us-east-1. Even if you only deploy to one region, IAM and other
#     global services generate events in us-east-1 — this ensures nothing
#     is missed.
#   - enable_log_file_validation = true: CloudTrail creates a digest file
#     every hour with a hash of all log files. This lets you prove logs
#     haven't been tampered with — a key compliance requirement.
#   - Management events only (no data events): Data events track individual
#     S3 object operations and Lambda invocations, which would generate
#     massive volume and cost for a lab. Management events cover the
#     "who created/modified/deleted what resource" questions.
#
# NOTE: The S3 bucket policy granting CloudTrail write access is managed
# by the S3 module (centralized to avoid single-bucket-policy conflicts).
# =============================================================================


# -----------------------------------------------------------------------------
# CLOUDTRAIL TRAIL
#
# The trail itself — the configuration that tells CloudTrail where to
# deliver events and how to encrypt them.
# -----------------------------------------------------------------------------

resource "aws_cloudtrail" "this" {
  name = "${var.project}-${var.environment}-trail"

  s3_bucket_name = var.s3_bucket_name
  s3_key_prefix  = var.s3_key_prefix

  kms_key_id = var.kms_key_arn

  is_multi_region_trail         = true
  include_global_service_events = true

  enable_log_file_validation = true
  enable_logging             = true

  tags = {
    Name = "${var.project}-${var.environment}-trail"
  }
}

moved {
  from = aws_cloudtrail.main
  to   = aws_cloudtrail.this
}

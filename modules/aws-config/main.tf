# modules/aws-config/main.tf
# =============================================================================
# AWS CONFIG: COMPLIANCE MONITORING
#
# This module creates:
#   1. IAM role for the AWS Config service
#   2. Configuration recorder (captures resource configuration changes)
#   3. Delivery channel (sends snapshots to S3)
#   4. Recorder status (starts the recorder)
#   5. Managed compliance rules (4 baseline rules)
#
# AWS Config has a quirky dependency chain in Terraform:
#   - The recorder must exist before the delivery channel
#   - The delivery channel must exist before the recorder can be started
#   - Config rules depend on the recorder being started
# This is why we need separate resources for the recorder and its status.
#
# AWS Config evaluates resources against rules and reports compliance.
# It doesn't enforce or remediate — it's an auditor, not a cop. If a
# resource is non-compliant, Config flags it. You decide what to do.
# =============================================================================


# -----------------------------------------------------------------------------
# IAM ROLE FOR AWS CONFIG
#
# Config needs an IAM role to:
#   - Read your resource configurations (via the AWS_ConfigRole managed policy)
#   - Write configuration snapshots to S3
#
# The AWS managed policy "AWS_ConfigRole" grants read-only access to
# describe resources across most AWS services. The S3 write permission
# comes from the bucket policy (created in the S3 module), not from
# this IAM role — Config uses the service principal for S3 delivery.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "config_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "config" {
  name               = "${var.project}-${var.environment}-config"
  assume_role_policy = data.aws_iam_policy_document.config_assume_role.json

  tags = {
    Name = "${var.project}-${var.environment}-config-role"
  }
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Config also needs permission to write to S3 and publish to SNS.
# The S3 bucket policy handles bucket writes. This inline policy
# covers the S3 PutObject for delivery and SNS Publish for notifications.
data "aws_iam_policy_document" "config_delivery" {
  statement {
    sid    = "AllowS3Delivery"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetBucketAcl",
    ]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.sns_topic_arn != "" ? [1] : []
    content {
      sid       = "AllowSNSPublish"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [var.sns_topic_arn]
    }
  }
}

resource "aws_iam_role_policy" "config_delivery" {
  name   = "${var.project}-${var.environment}-config-delivery"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_delivery.json
}


# -----------------------------------------------------------------------------
# CONFIGURATION RECORDER
#
# The recorder captures configuration changes for AWS resources.
# all_supported = true means it records ALL supported resource types.
# include_global_resource_types = true captures IAM and other global
# resources (only needed in one region — our primary us-east-1).
# -----------------------------------------------------------------------------

resource "aws_config_configuration_recorder" "this" {
  name     = "${var.project}-${var.environment}"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}


# -----------------------------------------------------------------------------
# DELIVERY CHANNEL
#
# Tells Config where to deliver configuration snapshots and history.
# We use the same S3 bucket as CloudTrail (different prefix).
#
# snapshot_delivery_properties controls how often Config delivers a
# full snapshot of all recorded resource configurations. "Six_Hours"
# is a reasonable balance for a lab — frequent enough to catch drift,
# not so frequent that it generates excessive S3 writes.
# -----------------------------------------------------------------------------

resource "aws_config_delivery_channel" "this" {
  name           = "${var.project}-${var.environment}"
  s3_bucket_name = var.s3_bucket_name
  s3_key_prefix  = var.s3_key_prefix
  sns_topic_arn  = var.sns_topic_arn != "" ? var.sns_topic_arn : null

  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this]
}


# -----------------------------------------------------------------------------
# RECORDER STATUS
#
# This is the "start button." The recorder exists but doesn't run
# until this resource enables it. It must be created after the
# delivery channel (otherwise there's nowhere for Config to send data).
# -----------------------------------------------------------------------------

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}


# -----------------------------------------------------------------------------
# MANAGED COMPLIANCE RULES
#
# AWS provides pre-built rules (managed rules) that evaluate common
# compliance requirements. Each rule has a source_identifier that maps
# to the rule logic maintained by AWS.
#
# All rules depend on the recorder being started (via the status resource).
#
# We use for_each with a local map to keep this DRY — adding a new rule
# is a one-line addition to the map.
# -----------------------------------------------------------------------------

locals {
  config_rules = {
    "s3-bucket-encryption" = {
      source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
      description       = "Checks that S3 buckets have server-side encryption enabled"
    }
    "restricted-ssh" = {
      source_identifier = "INCOMING_SSH_DISABLED"
      description       = "Checks that security groups do not allow unrestricted SSH (0.0.0.0/0 on port 22)"
    }
    "rds-storage-encrypted" = {
      source_identifier = "RDS_STORAGE_ENCRYPTED"
      description       = "Checks that RDS instances have storage encryption enabled"
    }
    "cloudtrail-enabled" = {
      source_identifier = "CLOUD_TRAIL_ENABLED"
      description       = "Checks that CloudTrail is enabled in the account"
    }
  }
}

resource "aws_config_config_rule" "rules" {
  for_each = local.config_rules

  name        = "${var.project}-${var.environment}-${each.key}"
  description = each.value.description

  source {
    owner             = "AWS"
    source_identifier = each.value.source_identifier
  }

  depends_on = [aws_config_configuration_recorder_status.this]

  tags = {
    Name = "${var.project}-${var.environment}-${each.key}"
  }
}

moved {
  from = aws_config_configuration_recorder.main
  to   = aws_config_configuration_recorder.this
}

moved {
  from = aws_config_delivery_channel.main
  to   = aws_config_delivery_channel.this
}

moved {
  from = aws_config_configuration_recorder_status.main
  to   = aws_config_configuration_recorder_status.this
}

# modules/cloudtrail/main.tf
# =============================================================================
# CLOUDTRAIL: API AUDIT LOGGING
#
# This module creates:
#   1. A CloudTrail trail capturing all management events
#   2. Delivery of that trail to a CloudWatch Logs group, and five metric
#      filters + alarms on it, the CIS AWS Foundations 3.x basics (#244):
#      root use, console sign-in without MFA, IAM policy changes, CloudTrail
#      configuration changes, and bursts of unauthorized API calls
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
#     massive volume and cost for this environment. Management events cover the
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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name      = "${var.project}-${var.environment}-trail"
  trail_arn = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${local.name}"
}

resource "aws_cloudtrail" "this" {
  name = local.name

  s3_bucket_name = var.s3_bucket_name
  s3_key_prefix  = var.s3_key_prefix

  kms_key_id = var.kms_key_arn

  # S3 stays the durable, validated archive; the CloudWatch Logs copy below
  # exists so the metric filters can see events within minutes (#244).
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail_to_logs.arn

  # CloudTrail test-writes with the role when the trail is updated, so the
  # role's policy must exist first; the role ARN alone does not order that.
  depends_on = [aws_iam_role_policy.trail_to_logs]

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


# -----------------------------------------------------------------------------
# CLOUDWATCH LOGS DELIVERY
#
# Metric filters read CloudWatch Logs, not S3, so the trail also delivers to
# this group. Volume: ~0.63 GB of events a month (the S3 archive for
# 2026-10-03..11-01, 109 MB gzipped at the measured 5.5x ratio; the busiest
# day was 4.6 MB gzipped), which keeps the account inside the 5 GB/month
# CloudWatch Logs free tier alongside its other groups (~2.9 GB/month). The retention is short
# because S3 holds the full, validated record; this copy only feeds alarms
# and recent-history queries.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name}-logs"
  }
}

data "aws_iam_policy_document" "trail_to_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    # Only this trail may use the role (confused deputy). The ARN is built
    # from its name, not read from the trail, which would be a cycle.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "trail_to_logs" {
  name               = "${local.name}-to-logs"
  assume_role_policy = data.aws_iam_policy_document.trail_to_logs_assume.json

  tags = {
    Name = "${local.name}-to-logs"
  }
}

data "aws_iam_policy_document" "trail_to_logs" {
  statement {
    sid       = "WriteTrailLogStreams"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "trail_to_logs" {
  name   = "${local.name}-to-logs"
  role   = aws_iam_role.trail_to_logs.id
  policy = data.aws_iam_policy_document.trail_to_logs.json
}


# -----------------------------------------------------------------------------
# CIS 3.x METRIC FILTERS AND ALARMS
#
# One filter and one alarm per control, all to the platform alert topic on
# ALARM and OK. The filter patterns follow the CIS AWS Foundations Benchmark.
# Each metric is sparse (it publishes only when a matching event arrives), so
# missing data is not breaching. Free: filters cost nothing, and the events
# are already in the log group above. docs/RUNBOOK.md ("Security alarms")
# says what to do when each one fires.
#
# The unauthorized-calls alarm has a threshold instead of firing on one
# event. The AWS Config recorder probes services it may not read (about 8
# AccessDenied a day, at most 2 in any 10 minutes, measured 2026-11-01); an
# enumeration attempt produces far more.
# -----------------------------------------------------------------------------

locals {
  cis_alarms = {
    root-account-use = {
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      threshold   = 1
      description = "the root user made an API call or signed in"
    }
    console-signin-no-mfa = {
      pattern     = "{ ($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed != \"Yes\") && ($.userIdentity.type = \"IAMUser\") && ($.responseElements.ConsoleLogin = \"Success\") }"
      threshold   = 1
      description = "an IAM user signed in to the console without MFA"
    }
    iam-policy-change = {
      pattern     = "{ ($.eventSource = iam.amazonaws.com) && (($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = DeletePolicyVersion) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = AttachUserPolicy) || ($.eventName = DetachUserPolicy) || ($.eventName = AttachGroupPolicy) || ($.eventName = DetachGroupPolicy)) }"
      threshold   = 1
      description = "an IAM policy was created, changed, attached or detached"
    }
    cloudtrail-config-change = {
      pattern     = "{ ($.eventName = CreateTrail) || ($.eventName = UpdateTrail) || ($.eventName = DeleteTrail) || ($.eventName = StartLogging) || ($.eventName = StopLogging) }"
      threshold   = 1
      description = "a CloudTrail trail was created, changed, deleted, started or stopped"
    }
    unauthorized-api-calls = {
      pattern     = "{ (($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\")) && ($.sourceIPAddress != \"delivery.logs.amazonaws.com\") && ($.eventName != \"HeadBucket\") }"
      threshold   = var.unauthorized_calls_threshold
      description = "unauthorized or access-denied API calls"
    }
  }

  cis_namespace = "${var.project}-${var.environment}/cloudtrail"
}

resource "aws_cloudwatch_log_metric_filter" "cis" {
  for_each = local.cis_alarms

  name           = "${local.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = local.cis_namespace
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cis" {
  for_each = local.cis_alarms

  alarm_name          = "${var.project}-${var.environment}-cis-${each.key}"
  alarm_description   = "CloudTrail: ${each.value.description} (${each.value.threshold} or more in 5 minutes). See docs/RUNBOOK.md, Security alarms."
  namespace           = local.cis_namespace
  metric_name         = each.key
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]

  # The filter must exist for its metric to; ordering keeps the first apply
  # from creating an alarm on a metric nothing will ever publish.
  depends_on = [aws_cloudwatch_log_metric_filter.cis]

  tags = {
    Name = "${var.project}-${var.environment}-cis-${each.key}"
  }
}

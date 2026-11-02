resource "aws_wafv2_web_acl" "this" {
  name        = "${var.project}-${var.environment}-waf"
  description = "WAF Web ACL for ${var.project}-${var.environment} ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # --- AWS Managed Rule Groups ---

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # --- Custom Rate-Based Rule ---

  rule {
    name     = "RateLimitPerIP"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.environment}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.environment}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "${var.project}-${var.environment}-waf"
    Project     = var.project
    Environment = var.environment
  }
}

# --- Associate WAF with ALB ---

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

moved {
  from = aws_wafv2_web_acl.main
  to   = aws_wafv2_web_acl.this
}

# --- Request logging (#245, decision 2 on lentago/.github#318) ---
#
# Every request the web ACL evaluates, allowed or blocked, is logged to
# CloudWatch Logs. WAF requires the log group's name to start with
# "aws-waf-logs-". A record holds the client IP and country, the URI and query
# string, the request headers, and the rule that terminated or counted the
# request. The authorization and cookie headers are redacted, so no credential
# or session token is written. The group stays on the default key, per ADR-0009
# decision 1: this is request metadata for operators, like the flow logs.
#
# Cost: the ACL saw about 490,000 requests in the 30 days to 2026-11-02 (~10%
# blocked). At an assumed 1.5–2.5 KB per record that is roughly 0.7–1.2 GB a
# month, billed as vended logs at $0.50/GB. The account ingested about 2.8 GB of
# logs in October 2026, plus about 0.5 GB a month for the CloudTrail copy since
# #244, so this volume still fits inside CloudWatch's 5 GB monthly free tier:
# about $0 now, at most ~$0.60 a month once the free tier is used up.
# Storage at 30 days' retention is cents. The volume scales with traffic, so
# a request flood raises it, alongside WAF's own per-request charge.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "aws-waf-logs-${var.project}-${var.environment}"
  }
}

# Delivery to CloudWatch Logs needs a Logs resource policy for the
# delivery.logs.amazonaws.com principal. When the caller can write one, WAF
# creates it implicitly, named AWSWAF-LOGS and outside Terraform. Declaring it
# here, scoped to this one group, and making the logging configuration wait for
# it keeps that policy in code.
data "aws_iam_policy_document" "waf_log_delivery" {
  statement {
    sid    = "WafLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf_log_delivery" {
  policy_name     = "${var.project}-${var.environment}-waf-log-delivery"
  policy_document = data.aws_iam_policy_document.waf_log_delivery.json
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf_log_delivery]
}

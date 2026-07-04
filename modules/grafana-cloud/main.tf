# modules/grafana-cloud/main.tf
# =============================================================================
# GRAFANA CLOUD — CROSS-ACCOUNT READ-ONLY ROLE
#
# Grafana Cloud's CloudWatch datasource supports "Grafana Assume Role":
# Grafana's own AWS account calls sts:AssumeRole into this role, presenting
# an External ID unique to our stack (lentago.grafana.net). This is the
# cross-account analog of our GitHub OIDC pattern — no long-lived keys.
#
# Trust policy = WHO may assume (Grafana's account, gated by External ID).
# Permission policy = WHAT they may do (read CloudWatch metrics, discover
# resources). Metrics only — no CloudWatch Logs actions; log shipping is
# Phase 2 and goes to Axiom (betula), not Grafana.
#
# The External ID condition prevents the confused-deputy problem: even
# though Grafana's account is the principal, only requests carrying OUR
# stack's External ID succeed.
#
# The datasource that consumes this role lives in lentago/drosera
# (terraform/datasources.tf, uid solidago-cloudwatch).
# =============================================================================

# --- Trust policy: who can assume this role? ---
data "aws_iam_policy_document" "grafana_assume" {
  statement {
    sid     = "GrafanaCloudAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.grafana_cloud_account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.grafana_cloud_external_id]
    }
  }
}

resource "aws_iam_role" "grafana_cloudwatch" {
  name               = "${var.project}-${var.environment}-grafana-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json

  tags = {
    Name = "${var.project}-${var.environment}-grafana-cloudwatch"
  }
}

# --- Permission policy: metrics read + resource discovery ---
# CloudWatch metric-read APIs do not support resource-level scoping, so
# resources = ["*"] is the floor here, not laziness. The action list is
# Grafana's documented minimum for the CloudWatch datasource, minus the
# logs:* group (deliberately excluded — Axiom/betula owns logs).
data "aws_iam_policy_document" "grafana_cloudwatch_read" {
  statement {
    sid = "CloudWatchMetricsRead"
    actions = [
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ResourceDiscovery"
    actions = [
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "grafana_cloudwatch_read" {
  name   = "${var.project}-${var.environment}-grafana-cloudwatch-readonly"
  role   = aws_iam_role.grafana_cloudwatch.id
  policy = data.aws_iam_policy_document.grafana_cloudwatch_read.json
}

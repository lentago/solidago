# modules/guardduty/main.tf
# =============================================================================
# GUARDDUTY: THREAT DETECTION, FINDINGS TO THE ALERT TOPIC (#243)
#
# Decision 2 on lentago/.github#318 (2026-11-02): GuardDuty on, with a budget
# alarm. The alarm is the `guardduty` entry in modules/budgets'
# service_budgets, on the same alert topic.
#
# GuardDuty reads CloudTrail management events, VPC flow logs and DNS query
# logs from its own feeds. It does not use the trail, the flow-log group or
# anything else this stack ships. Findings of severity 4 (medium) and above go
# to the alert topic through an EventBridge rule. Low findings stay in the
# console.
#
# Protection plans. CreateDetector turns on every optional plan the caller does
# not name, except Runtime Monitoring. Each plan the pinned AWS provider
# (5.100.0) knows is declared in local.protection_plans, so its setting is in
# code rather than left to the service default:
#
#   S3_DATA_EVENTS          on   S3 data events: state, trail, ALB-log buckets
#   RDS_LOGIN_EVENTS        on   login activity on solidago-dev-postgres
#   LAMBDA_NETWORK_LOGS     on   network activity of the stack's functions
#   EKS_AUDIT_LOGS          on   no standing cluster; osmunda's ephemeral EKS
#                                overlay ran here once (2026-08-17), and a
#                                session's audit events cost cents
#   EBS_MALWARE_PROTECTION  on   scans an EC2 volume after a finding; no EC2
#   RUNTIME_MONITORING      off  agent-based, billed per vCPU, and the Fargate
#                                tasks would need the agent sidecar
#
# AI Protection (AI_PROTECTION) postdates the pinned provider, cannot be
# declared here, and stays at the service default, which is on. It analyzes
# Bedrock, AgentCore and SageMaker activity, none of which this account uses,
# so it has nothing to bill.
#
# Cost, estimated from this account's volumes on 2026-11-02 (us-east-1):
#   CloudTrail management events  ~350k/month (~480/h)  x $4.00/M    ~ $1.40
#   VPC flow + DNS query logs     ~2.3 GB/month          x $1.00/GB   ~ $2.50
#   RDS login events              db.t4g.micro, 2 vCPU   x $1.00      = $2.00
#   S3 data events                under 0.2M/month       x $0.80/M    < $0.20
#   Lambda network activity       three low-traffic functions         ~ $0.05
#   EKS, EBS malware scans, AI    none standing                        ~ $0
#   Total about $6 a month (range $4-8). The first 30 days are a free trial.
#   GuardDuty's usage page (or `aws guardduty get-usage-statistics`) shows the
#   real figure once the detector runs.
# =============================================================================

locals {
  protection_plans = {
    S3_DATA_EVENTS         = "ENABLED"
    RDS_LOGIN_EVENTS       = "ENABLED"
    LAMBDA_NETWORK_LOGS    = "ENABLED"
    EKS_AUDIT_LOGS         = "ENABLED"
    EBS_MALWARE_PROTECTION = "ENABLED"
    RUNTIME_MONITORING     = "DISABLED"
  }
}

resource "aws_guardduty_detector" "this" {
  enable = true

  tags = {
    Name = "${var.project}-${var.environment}-guardduty"
  }
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = local.protection_plans

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  status      = each.value
}

# --- Findings to the alert topic ---------------------------------------------

resource "aws_cloudwatch_event_rule" "findings" {
  name        = "${var.project}-${var.environment}-guardduty-findings"
  description = "GuardDuty findings of severity ${var.min_alert_severity} and above, to the alert topic"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", var.min_alert_severity] }]
    }
  })

  tags = {
    Name = "${var.project}-${var.environment}-guardduty-findings"
  }
}

# A readable email rather than the raw event. Each quoted line of the template
# becomes one line of the message (the form GuardDuty's own guide uses). The
# topic policy's AllowEventBridgePublish statement (modules/monitoring) lets
# the rule publish.
resource "aws_cloudwatch_event_target" "findings_to_topic" {
  rule      = aws_cloudwatch_event_rule.findings.name
  target_id = "alert-topic"
  arn       = var.alarm_topic_arn

  input_transformer {
    input_paths = {
      severity = "$.detail.severity"
      type     = "$.detail.type"
      title    = "$.detail.title"
      account  = "$.account"
      region   = "$.region"
      id       = "$.detail.id"
    }

    input_template = <<-EOT
      "GuardDuty finding, severity <severity>: <type>"
      "<title>"
      "Account <account>, region <region>."
      "https://<region>.console.aws.amazon.com/guardduty/home?region=<region>#/findings?macros=current&fId=<id>"
    EOT
  }
}

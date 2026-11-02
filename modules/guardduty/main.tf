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
#   RDS_LOGIN_EVENTS        on   login activity on solidago-dev-postgres; its
#                                RDS_DATA_RISK sub-setting is off (below)
#   LAMBDA_NETWORK_LOGS     on   network activity of the stack's functions
#   EKS_AUDIT_LOGS          on   no standing cluster; osmunda's ephemeral EKS
#                                overlay ran here once (2026-08-17), and a
#                                session's audit events cost cents
#   EBS_MALWARE_PROTECTION  on   scans an EC2 volume after a finding; no EC2
#   RUNTIME_MONITORING      off  agent-based, billed per vCPU, and the Fargate
#                                tasks would need the agent sidecar
#
# Newer than the pinned provider, so not declarable here (bump: #261):
#   - AI_PROTECTION (watches Bedrock, AgentCore and SageMaker activity) and
#     AI_ANALYST. CreateDetector left both DISABLED, so they cost nothing.
#   - RDS_DATA_RISK, RDS Protection's data-activity monitoring, a sub-setting
#     of RDS_LOGIN_EVENTS at $3 per vCPU-month ($6 here). CreateDetector turns
#     it ON. The provider rejects the name, so terraform_data.rds_data_risk_off
#     below turns it off with the CLI. Nothing uses this database (#242), so
#     login anomalies are the signal worth paying for and data activity is not.
#   - The runtime agent-management sub-settings are known to the provider but
#     only matter while RUNTIME_MONITORING is on; all three are DISABLED.
# The feature resources ignore additional_configuration, so these sub-settings
# don't show as a perpetual replacement in every plan (#262). The cost: a
# console change to them is not reported as drift, and a sub-setting declared
# here later would be ignored too, so #261 removes the ignore. Live state read
# on 2026-11-02 with `aws guardduty get-detector --detector-id <id>`.
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

data "aws_region" "current" {}

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

  # Sub-settings GuardDuty attaches on its own (RDS_DATA_RISK; the runtime
  # agent-management trio) would otherwise force a replacement every plan,
  # because additional_configuration is ForceNew. See the header and #261.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

# Turns off RDS_DATA_RISK, which the pinned provider cannot name (#261, #262).
# Runs in the apply job with the apply role's guardduty:UpdateDetector and
# GetDetector, then reads the setting back and fails the apply unless it is
# DISABLED. It re-runs when the detector is replaced, when the RDS_LOGIN_EVENTS
# feature is created, replaced or updated, or when that feature's status
# changes here, since any of those could bring back the service default.
# Remove it once additional_configuration can declare the setting.
resource "terraform_data" "rds_data_risk_off" {
  triggers_replace = {
    detector_id      = aws_guardduty_detector.this.id
    rds_login_events = local.protection_plans["RDS_LOGIN_EVENTS"]
    rds_data_risk    = "DISABLED"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      aws guardduty update-detector --region ${data.aws_region.current.name} \
        --detector-id ${aws_guardduty_detector.this.id} \
        --features '[{"Name":"RDS_LOGIN_EVENTS","Status":"${local.protection_plans["RDS_LOGIN_EVENTS"]}","AdditionalConfiguration":[{"Name":"RDS_DATA_RISK","Status":"DISABLED"}]}]'
      for attempt in 1 2 3 4 5 6; do
        status=$(aws guardduty get-detector --region ${data.aws_region.current.name} \
          --detector-id ${aws_guardduty_detector.this.id} \
          --query "Features[?Name=='RDS_LOGIN_EVENTS'] | [0].AdditionalConfiguration[?Name=='RDS_DATA_RISK'] | [0].Status" \
          --output text)
        echo "RDS_DATA_RISK is $status (read $attempt)"
        [ "$status" = "DISABLED" ] && exit 0
        sleep 5
      done
      echo "RDS_DATA_RISK did not read back DISABLED" >&2
      exit 1
    EOT
  }

  lifecycle {
    replace_triggered_by = [aws_guardduty_detector_feature.this["RDS_LOGIN_EVENTS"]]
  }
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

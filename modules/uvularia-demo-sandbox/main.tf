# modules/uvularia-demo-sandbox/main.tf
#
# =============================================================================
# UVULARIA DEMO SANDBOX  (issue #195)
#
# The lentago/uvularia demonstration "Ask" function runs in THIS account — the
# only one we have — but is fenced off so it looks and behaves isolated from the
# solidago platform that serves lentago.dev. The stronger option (a separate
# member account under AWS Organizations) is noted for later; nothing here
# precludes it. ADR-0007's no-multi-tenancy rule and plain honesty both want the
# demo's cloud footprint separable from the platform.
#
# This module is applied from environments/dev by solidago's Terraform pipeline.
# It mints the fence; it does NOT deploy the demo. The demo's own repo,
# lentago/uvularia-demo-ask-rules, assumes the role below via OIDC and Terraforms
# the actual Lambda / function URL / DynamoDB / log group INTO the fence.
#
# What the fence is:
#   1. OIDC deploy role  uvularia-demo-ask-deploy  — trusts ONLY the rules repo,
#      no access to anything solidago owns except its own slice of remote state.
#   2. Permissions boundary  uvularia-demo-boundary  — the hard ceiling, attached
#      to the deploy role and REQUIRED on every role the deploy role creates.
#      Services: Lambda (+ function URLs), IAM (prefixed + boundary-bound only),
#      DynamoDB, SSM Parameter Store (read /uvularia-demo/* only), CloudWatch
#      Logs, and nothing else. Resource ARNs pinned to the uvularia-demo- prefix
#      wherever the service supports it.
#   3. State isolation — read/write ONLY solidago-tfstate-<acct>/uvularia-demo/
#      ask.tfstate, the DynamoDB lock rows for that one key, and a KMS grant on
#      the state CMK limited the same way.
#   4. A $5/month budget and a function-error alarm, on a dedicated SNS topic.
#   5. The secret SLOT, not the secret: the SSM path /uvularia-demo/anthropic-api-key
#      is documented and read-granted, but the value is written by hand — never
#      in Terraform state or a repo (see README).
#
# What it canNOT isolate: same AWS account, same bill, same region. The boundary
# and the prefix are what make the single-account version defensible.
#
# To delete the whole sandbox in one apply: remove module.uvularia_demo_sandbox
# from environments/dev (and its outputs) and apply — every resource here is
# self-contained. (Empty the demo's own stack from the rules repo first, or its
# orphaned resources outlive the fence.) See README.
# =============================================================================

locals {
  prefix       = "uvularia-demo"
  deploy_role  = "${local.prefix}-ask-deploy"
  boundary     = "${local.prefix}-boundary"
  state_bucket = "solidago-tfstate-${var.aws_account_id}"
  state_key    = "uvularia-demo/ask.tfstate"
  lock_table   = "solidago-tfstate-lock"

  # Constructed, not referenced from the resource, to avoid a dependency cycle:
  # the deploy policy's CreateRole condition names the boundary ARN, while the
  # boundary policy is built from the deploy policy document.
  boundary_arn = "arn:aws:iam::${var.aws_account_id}:policy/${local.boundary}"

  # The fence's own three IAM objects. The deploy role must never be able to
  # rewrite these (CodeRabbit finding on #196: the uvularia-demo-* prefix glob
  # matched them, so the role could have replaced its own boundary with *:*).
  deploy_role_arn   = "arn:aws:iam::${var.aws_account_id}:role/${local.deploy_role}"
  deploy_policy_arn = "arn:aws:iam::${var.aws_account_id}:policy/${local.deploy_role}"

  # Remote-state targets — the ONLY solidago-owned things the role may touch.
  state_bucket_arn = "arn:aws:s3:::${local.state_bucket}"
  state_object_arn = "arn:aws:s3:::${local.state_bucket}/${local.state_key}"
  lock_table_arn   = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${local.lock_table}"
  # Terraform's S3+DynamoDB backend writes two lock items for a state key: the
  # lock itself and its "-md5" digest. The LeadingKeys condition pins the role
  # to exactly these two rows — it cannot touch any other repo's lock.
  lock_ids = [
    "${local.state_bucket}/${local.state_key}",
    "${local.state_bucket}/${local.state_key}-md5",
  ]

  # Resource globs — every service scoped to the uvularia-demo- prefix.
  fn_arn_glob     = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${local.prefix}-*"
  role_arn_glob   = "arn:aws:iam::${var.aws_account_id}:role/${local.prefix}-*"
  policy_arn_glob = "arn:aws:iam::${var.aws_account_id}:policy/${local.prefix}-*"
  ddb_arn_glob    = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${local.prefix}-*"
  ddb_idx_glob    = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${local.prefix}-*/index/*"
  ssm_read_glob   = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${local.prefix}/*"
  log_arn_glob    = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${local.prefix}-*:*"

  tags = { Project = "uvularia-demo" }
}

# =============================================================================
# DEPLOY ROLE — OIDC trust
#
# Trusts ONLY the rules repo, and only its main branch (apply) plus the fixed
# pull_request subject GitHub issues for any PR-triggered run (plan). Same
# two-value StringEquals shape as the dotgithub cross-repo role in modules/iam.
# The rules repo is young enough to possibly emit GitHub's immutable numeric sub
# form; if its deploys 403 on AssumeRoleWithWebIdentity, swap these for the
# "repo:<org>@<id>/<repo>@<id>:..." form (see the pondview entry in
# environments/dev/main.tf for the precedent).
# =============================================================================
data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.rules_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.rules_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600

  tags = merge(local.tags, { Name = local.deploy_role })
}

# =============================================================================
# DEPLOY ROLE — permissions
#
# Exactly what the rules repo needs to stand up its demo, and nothing more. The
# first three statements are the remote-state MECHANISM (the one slice of
# solidago it may touch); the rest are the demo's own services, all pinned to
# the uvularia-demo- prefix. SSM read is intentionally absent here — the deploy
# role never reads the Anthropic key; only the function's runtime role does
# (granted by the rules repo, capped by the boundary below).
# =============================================================================
data "aws_iam_policy_document" "deploy" {
  # --- Remote state: one object, its lock rows, its CMK --------------------
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.state_object_arn]
  }

  # The S3 backend lists the bucket before it reads or writes the state object;
  # without ListBucket a missing object reads as 403 and init fails. Scoped to
  # this state's prefix only.
  statement {
    sid       = "TerraformStateList"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.state_key}", "${local.state_key}*", "uvularia-demo/*"]
    }
  }


  statement {
    sid = "TerraformStateKMS"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.tfstate_kms_key_arn]
  }

  statement {
    sid = "TerraformStateLock"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [local.lock_table_arn]
    # Restrict item access to this state key's two lock rows. DescribeTable
    # carries no LeadingKeys and passes vacuously (ForAllValues over an empty
    # request set is true), so refresh still works; the item ops are pinned.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = local.lock_ids
    }
  }

  # --- Lambda + function URLs (function-URL actions are part of lambda:*) ---
  statement {
    sid       = "LambdaManage"
    actions   = ["lambda:*"]
    resources = [local.fn_arn_glob]
  }

  # --- IAM: manage prefixed roles/policies (no principal-boundary mutation) -
  statement {
    sid = "IAMManagePrefixed"
    actions = [
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListEntitiesForPolicy",
    ]
    resources = [local.role_arn_glob, local.policy_arn_glob]
  }

  # CreateRole only with the uvularia-demo- name prefix (resource) AND this
  # boundary (condition). This is the clause that makes the fence self-propagate
  # to every role the demo stands up.
  statement {
    sid       = "IAMCreateRoleWithBoundary"
    actions   = ["iam:CreateRole"]
    resources = [local.role_arn_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  # PassRole only for prefixed roles, and only to Lambda.
  statement {
    sid       = "IAMPassRole"
    actions   = ["iam:PassRole"]
    resources = [local.role_arn_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # --- The fence protects itself -------------------------------------------
  # Explicit Deny beats every Allow above, and because the boundary is composed
  # from this document the same denies bind every role the demo creates.
  statement {
    sid    = "DenyRewritingTheFence"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.deploy_role_arn, local.deploy_policy_arn, local.boundary_arn]
  }

  # No demo role may ever shed its boundary, or swap it for another one.
  statement {
    sid       = "DenyRemovingAnyBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = [local.role_arn_glob]
  }
  statement {
    sid       = "DenySwappingTheBoundary"
    effect    = "Deny"
    actions   = ["iam:PutRolePermissionsBoundary", "iam:CreateRole"]
    resources = [local.role_arn_glob]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  # --- DynamoDB: the demo's own tables --------------------------------------
  statement {
    sid       = "DynamoDBAppTables"
    actions   = ["dynamodb:*"]
    resources = [local.ddb_arn_glob, local.ddb_idx_glob]
  }

  # --- CloudWatch Logs: the demo's own log groups ---------------------------
  statement {
    sid       = "LogsManagePrefixed"
    actions   = ["logs:*"]
    resources = [local.log_arn_glob]
  }

  # DescribeLogGroups is a list operation and does not support resource-level
  # scoping, so it is granted on "*" (read-only metadata only) — the same
  # carve-out modules/iam uses for ECS/ECR list actions.
  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = local.deploy_role
  policy = data.aws_iam_policy_document.deploy.json

  tags = merge(local.tags, { Name = local.deploy_role })
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}

# =============================================================================
# PERMISSIONS BOUNDARY
#
# The ceiling for the deploy role AND for every role it creates (the function's
# runtime role). Built as a SUPERSET of the deploy policy (so the deploy policy
# is never silently capped to nothing) plus one extra surface the deploy role
# does not have but the runtime role needs: reading /uvularia-demo/* from SSM.
# Composing from the deploy document guarantees the superset relationship holds
# even as the deploy policy evolves.
# =============================================================================
data "aws_iam_policy_document" "boundary" {
  source_policy_documents = [data.aws_iam_policy_document.deploy.json]

  # The runtime role reads the Anthropic key from its SSM SecureString slot.
  # Read-only, scoped to the /uvularia-demo/ path.
  statement {
    sid = "SSMReadPrefixed"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParameterHistory",
      "ssm:GetParametersByPath",
    ]
    resources = [local.ssm_read_glob]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary
  description = "Hard permissions ceiling for the uvularia demo sandbox (issue #195). Attached to uvularia-demo-ask-deploy and required on every role it creates."
  policy      = data.aws_iam_policy_document.boundary.json

  tags = merge(local.tags, { Name = local.boundary })
}

# =============================================================================
# ALERTING — dedicated SNS topic (not solidago's), budget, error alarm
#
# The sandbox carries its own notification channel so nothing here reaches into
# solidago's monitoring topic. One email subscription feeds both the budget
# threshold and the function error alarm.
# =============================================================================

# trivy:ignore:AVD-AWS-0095 — unencrypted by design, matching module.monitoring:
# the free aws/sns managed key cannot grant budgets/cloudwatch publish rights,
# and a paid CMK is unjustified for a sandbox alert channel. Tracked fleet-wide
# in #180 item 3.
#trivy:ignore:AVD-AWS-0095
resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"

  tags = merge(local.tags, { Name = "${local.prefix}-alerts" })
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# $5/month, scoped to the sandbox by its Project tag. NOTE: the tag-based cost
# filter only sees spend once the "Project" cost-allocation tag is activated in
# Billing (a one-time, console-only step — see README). Until then the budget
# tracks $0 and simply never false-alarms.
resource "aws_budgets_budget" "this" {
  name         = local.prefix
  budget_type  = "COST"
  limit_amount = var.monthly_budget_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$uvularia-demo"]
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }

  # Budgets validates publish permission to the topic at create time, so the
  # topic policy granting budgets.amazonaws.com must land first.
  depends_on = [aws_sns_topic_policy.alerts]

  tags = merge(local.tags, { Name = "${local.prefix}-budget" })
}

# Error alarm on the demo function. The function is created by the rules repo,
# so this references it by name (var.function_name) rather than by resource.
resource "aws_cloudwatch_metric_alarm" "ask_errors" {
  alarm_name          = "${local.prefix}-ask-errors"
  alarm_description   = "uvularia demo Ask function errors above ${var.error_alarm_threshold} per 5-minute period"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.error_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, { Name = "${local.prefix}-ask-errors" })
}

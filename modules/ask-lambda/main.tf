# modules/ask-lambda/main.tf

# =============================================================================
# "Ask the Wiki" answer endpoint (Lambda + public function URL)
#
# The composed-answer half of a static site's "Ask the Wiki" feature. The site
# does retrieval in the browser (a build-time RAG index) and POSTs the top
# passages to this function's URL; the function calls claude-haiku-4-5 with
# ONLY those passages and returns a short grounded answer. Nothing is stored;
# the knowledge base never leaves the site build.
#
#   browser --(question + top passages)--> function URL --> Anthropic API
#                                           (compose answer, return JSON)
#
# Shape mirrors modules/alb-log-shipper (archive_file package, least-privilege
# role, pre-created log group). Differences: this is Node (not Python), and it
# is reached by a public function URL (auth NONE, CORS-locked to the site origin
# and rate-capped in the handler) rather than an S3 trigger.
#
# ABUSE BOUNDS (#241). The URL is public by design, so spend is bounded in
# layers, innermost first:
#
#   1. Reserved concurrency (var.reserved_concurrency, default 2): at most that
#      many answers in flight; the rest are throttled before any code runs.
#   2. An optional Cloudflare Turnstile check (var.turnstile_enabled, off until
#      the site embeds the widget); the secret is an out-of-band SSM slot like
#      the key.
#   3. A durable daily cap: one atomic DynamoDB counter per UTC day, claimed
#      only by a request that passed every other check, so the ceiling holds
#      across containers and rejected requests never spend it. A claimed slot
#      is not refunded when the model call then fails or times out: the call
#      was made and may still be billed, and the cap bounds calls, not
#      successes.
#   4. An upstream timeout below the Lambda timeout, so a hung model call ends
#      as a logged 504 rather than a platform kill.
#   5. The OUTER BOUND is the spend cap on the Anthropic key, set in the
#      Anthropic console. Everything above is a belt under it; none replaces it.
#
# Alarms on Errors, Throttles and the URL's 5xx count go to the platform alert
# topic (var.alarm_topic_arn). The cap table, the counter logic and Turnstile
# are ported from uvularia's templates/ask-function.
#
# THE KEY IS NOT A TERRAFORM VALUE (#230). The Anthropic key lives in an SSM
# SecureString at local.api_key_ssm_path, written by hand. Terraform creates
# neither the parameter nor its value. It only passes the parameter PATH to the
# function and grants the role read on that one parameter. The handler reads
# the key on its first request per container. A key passed as a sensitive
# variable is redacted in plan output but still lands in tfstate (and in every
# saved plan), which is what this replaced. Same pattern as uvularia's
# templates/ask-function.
#
# Create the parameter once, out of band, before or after the first apply,
# with the real key, or with PLACEHOLDER-set-out-of-band until you have one:
#
#   aws ssm put-parameter --type SecureString \
#     --key-id alias/<project>-<environment>-main \
#     --name /<project>-<environment>-<name>-ask/anthropic-api-key \
#     --value '<key>'
#
# and rotate it later with the same command plus --overwrite. Use the platform
# CMK (--key-id), not the default aws/ssm key: the aws/ssm key policy lets ANY
# principal in the account that holds ssm:GetParameter decrypt, and AWS
# ReadOnlyAccess grants ssm:Get*. The CMK's policy delegates to IAM, so only
# roles granted kms:Decrypt on it (this function's, scoped below to this one
# parameter, and the apply role) can read the key. Until a real key on the CMK
# is there, the endpoint answers 502 and the Terraform workflow's post-apply
# "Check out-of-band secrets" step fails the run (the #213 pattern: present is
# not the same as set).
#
# The handler source is vendored at src/handler.mjs; see its header for the
# reference-copy sync note.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name          = "${var.project}-${var.environment}-${var.name}-ask"
  log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project}-${var.environment}-${var.name}-ask"

  # The out-of-band key slot (see the header). A hierarchical parameter name
  # starts with "/", so the ARN is "...:parameter" + the name.
  api_key_ssm_path = "/${local.name}/anthropic-api-key"
  api_key_ssm_arn  = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.api_key_ssm_path}"

  # The Turnstile secret's out-of-band slot, same conventions as the key. Read
  # (and granted) only when var.turnstile_enabled.
  turnstile_ssm_path = "/${local.name}/turnstile-secret"
  turnstile_ssm_arn  = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.turnstile_ssm_path}"

  secret_parameter_arns = concat(
    [local.api_key_ssm_arn],
    var.turnstile_enabled ? [local.turnstile_ssm_arn] : [],
  )

  # The model call is aborted this long before the Lambda timeout, leaving
  # time to log and return a 504 (validated >= 20s in variables.tf).
  upstream_timeout_ms = (var.lambda_timeout - 10) * 1000
}

# --- Package the handler ------------------------------------------------------
# The handler is dependency-free (global fetch, no npm install), so the zip is
# just the source dir. archive_file evaluates at plan time and is byte-stable
# for unchanged source, so there's no perpetual Lambda diff.
#
# CI NOTE: editing only files under src/ (e.g. the handler's SYSTEM prompt)
# changes source_code_hash and IS a real infra change. The Terraform workflow's
# change filter includes modules/*/src/** (see .github/workflows/terraform.yml),
# so a src-only PR correctly runs plan/apply and redeploys. (It formerly keyed on
# *.tf/*.tfvars only and silently skipped such edits — hence this note.)
data "archive_file" "this" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/ask.zip"
}

# --- Execution role (least privilege) ----------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = {
    Name = local.name
  }
}

# Write to the function's own CloudWatch log group (pre-created below), claim
# daily-cap slots in its own table, and read the SSM parameters that hold the
# Anthropic key (and the Turnstile secret, when enabled). The Anthropic and
# Turnstile calls themselves go over the public internet and need no IAM.
data "aws_iam_policy_document" "this" {
  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.log_group_arn}:*"]
  }

  # The handler only ever increments (a conditional UpdateItem); it never
  # reads, scans or deletes.
  statement {
    sid       = "DailyCapCounter"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.this.arn]
  }

  statement {
    sid       = "ReadSecretParameters"
    actions   = ["ssm:GetParameter"]
    resources = local.secret_parameter_arns
  }

  # SSM decrypts a SecureString on the caller's behalf, which needs kms:Decrypt
  # on the key behind it (the platform CMK, per the header). The conditions
  # bind the grant to SSM decrypting THESE parameters: SSM passes the parameter
  # ARN as encryption context, so the role can decrypt nothing else, through
  # SSM or directly.
  statement {
    sid       = "DecryptSecretsViaSSM"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = local.secret_parameter_arns
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${local.name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

# --- The durable daily cap ----------------------------------------------------
# One item per UTC day ("day" = YYYY-MM-DD); the handler's conditional
# increment is the cap. A TTL on "expires" lets DynamoDB delete old counters
# for free, so the table never grows. Provisioned 1/1 stays inside the
# always-free 25-unit tier: one write per answer, at most two in flight, and
# DynamoDB's burst credit absorbs two claims in the same second (the SDK
# retries a throttled write). The rows hold a date and a
# number, nothing about any visitor, so the default AWS-owned encryption is
# enough and point-in-time recovery would protect nothing worth keeping.
resource "aws_dynamodb_table" "this" {
  name           = "${local.name}-caps"
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "day"

  attribute {
    name = "day"
    type = "S"
  }

  ttl {
    attribute_name = "expires"
    enabled        = true
  }

  tags = {
    Name = "${local.name}-caps"
  }
}

# --- Function + its log group ------------------------------------------------
# Pre-create the log group (with retention) rather than let Lambda create it
# lazily, so the execution role never needs logs:CreateLogGroup.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name}-logs"
  }
}

resource "aws_lambda_function" "this" {
  function_name = local.name
  role          = aws_iam_role.this.arn
  runtime       = "nodejs22.x"
  handler       = "handler.handler"

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_size

  # The hard ceiling on answers in flight (#241). Requests past it are
  # throttled (HTTP 429 from the URL) before the handler runs.
  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      ANTHROPIC_API_KEY_SSM_PATH = local.api_key_ssm_path
      ALLOWED_ORIGIN             = var.allowed_origin
      CAP_TABLE                  = aws_dynamodb_table.this.name
      DAILY_REQUEST_CAP          = tostring(var.daily_request_cap)
      UPSTREAM_TIMEOUT_MS        = tostring(local.upstream_timeout_ms)
      TURNSTILE_ENABLED          = var.turnstile_enabled ? "1" : "0"
      TURNSTILE_SECRET_SSM_PATH  = var.turnstile_enabled ? local.turnstile_ssm_path : ""
    }
  }

  depends_on = [
    aws_iam_role_policy.this,
    aws_cloudwatch_log_group.this,
  ]

  tags = {
    Name = local.name
  }
}

# --- Public function URL ------------------------------------------------------
# auth NONE: the endpoint is unauthenticated by design (a public "ask" box).
# Abuse is bounded by the layers in the header (reserved concurrency, the
# optional Turnstile check, the durable daily cap, the upstream timeout) and,
# outermost, the spend cap on the Anthropic key itself. CORS, locked to
# var.allowed_origin, keeps other sites' pages from calling it in a browser
# but does not stop a script. The site embeds this URL at build time
# (PUBLIC_ASK_ENDPOINT).
#
# CORS is handled ENTIRELY by the function (handler.mjs): it answers the OPTIONS
# preflight (204) and stamps the Access-Control-* headers on every response,
# echoing ALLOWED_ORIGIN. We deliberately do NOT set the function URL's own
# `cors {}` block: when both are present, AWS's CORS layer AND the handler each
# add an `access-control-allow-origin` header, and browsers reject the duplicate
# with a "Failed to fetch" CORS error (curl, which ignores CORS, is unaffected —
# so this only shows up in a real browser). One authority, one set of headers.
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"
}

# A public (NONE-auth) function URL needs the resource-based policy to grant
# the anonymous principal TWO actions, and every request 403s if either is
# missing:
#
#   1. lambda:InvokeFunctionUrl  — reach the URL (scoped to auth type NONE).
#   2. lambda:InvokeFunction     — actually invoke the function behind it.
#
# The second grant became mandatory for function URLs created on/after October
# 2025 (AWS "urls-auth" docs). The pinned AWS provider (5.100) auto-adds only
# the InvokeFunctionUrl grant for a NONE URL, so without the explicit
# InvokeFunction grant below the endpoint returns 403 to every anonymous
# caller even though the function itself is healthy.
#
# Ideally the InvokeFunction grant is scoped to URL-origin requests with the
# lambda:InvokedViaFunctionUrl condition (as the AWS console/newer providers
# do). Provider 5.100's aws_lambda_permission exposes no argument for that
# condition key (only function_url_auth_type, which is not a valid condition
# key for the InvokeFunction action), so this grant is unconditioned. That is
# an acceptable trade here: the endpoint is public by design, the function is a
# stateless answer-composer that exposes no data, and its abuse ceiling is the
# Anthropic key's spend cap regardless of how it is invoked. Revisit (scope to
# InvokedViaFunctionUrl) if the AWS provider is upgraded to a version that
# supports it.
resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.this.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke_function" {
  statement_id  = "AllowPublicInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "*"
}

# --- Alarms --------------------------------------------------------------------
# Three views of "the box is failing", all to the platform alert topic, on
# ALARM and on recovery. Each metric is sparse (no data point when nothing
# happened), so missing data is not breaching.
#
#   Errors     unhandled failures: a crash, a platform timeout, a network error
#              on the model call (the handler rethrows those).
#   Throttles  requests turned away by reserved concurrency: a burst past
#              var.reserved_concurrency, or someone hammering the URL.
#   Url5xxCount  every 5xx the URL returned, including the handled ones that
#              never count as Errors: 502 (no key, or the model API failed),
#              503 (cap table unreachable), 504 (upstream timeout).
locals {
  alarms = {
    errors = {
      metric      = "Errors"
      threshold   = var.errors_alarm_threshold
      description = "unhandled errors"
    }
    throttles = {
      metric      = "Throttles"
      threshold   = var.throttles_alarm_threshold
      description = "throttled requests (reserved concurrency ${var.reserved_concurrency})"
    }
    url-5xx = {
      metric      = "Url5xxCount"
      threshold   = var.url_5xx_alarm_threshold
      description = "5xx responses from the function URL"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = "${local.name}: ${each.value.description} above ${each.value.threshold} per 5-minute period"
  namespace           = "AWS/Lambda"
  metric_name         = each.value.metric
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]

  tags = {
    Name = "${local.name}-${each.key}"
  }
}

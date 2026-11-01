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
# THE KEY IS NOT A TERRAFORM VALUE (#230). The Anthropic key lives in an SSM
# SecureString at local.api_key_ssm_path, written by hand. Terraform creates
# neither the parameter nor its value. It only passes the parameter PATH to the
# function and grants the role read on that one parameter. The handler reads
# the key on its first request per container. A key passed as a sensitive
# variable is redacted in plan output but still lands in tfstate (and in every
# saved plan), which is what this replaced. Same pattern as uvularia's
# templates/ask-function.
#
# Create the parameter once, out of band, with the placeholder, before or after
# the first apply:
#
#   aws ssm put-parameter --type SecureString \
#     --name /<project>-<environment>-<name>-ask/anthropic-api-key \
#     --value PLACEHOLDER-set-out-of-band
#
# then write the real key (and rotate it later) with the same command plus
# --overwrite and the key as --value. Until a real key is there, the endpoint
# answers 502 and the Terraform workflow's post-apply "Check out-of-band
# secrets" step fails the run (the #213 pattern: present is not the same as set).
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

# Write to the function's own CloudWatch log group (pre-created below) and
# read the one SSM parameter that holds the Anthropic key. The Anthropic API
# call itself goes over the public internet and needs no IAM.
data "aws_iam_policy_document" "this" {
  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.log_group_arn}:*"]
  }

  statement {
    sid       = "ReadApiKeyParameter"
    actions   = ["ssm:GetParameter"]
    resources = [local.api_key_ssm_arn]
  }

  # SSM decrypts a SecureString on the caller's behalf, which needs kms:Decrypt
  # on the key behind it (the account's aws/ssm key unless the parameter was
  # written with --key-id). The conditions bind the grant to SSM decrypting
  # THIS parameter: SSM passes the parameter ARN as encryption context, so the
  # role can decrypt nothing else, through SSM or directly.
  statement {
    sid       = "DecryptApiKeyViaSSM"
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
      values   = [local.api_key_ssm_arn]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${local.name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
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

  environment {
    variables = {
      ANTHROPIC_API_KEY_SSM_PATH = local.api_key_ssm_path
      ALLOWED_ORIGIN             = var.allowed_origin
      DAILY_REQUEST_CAP          = tostring(var.daily_request_cap)
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
# Abuse is bounded by (a) the handler's own CORS enforcement, locked to
# var.allowed_origin, (b) the handler's per-container daily request cap, and
# (c) the spend cap on the Anthropic key itself. The site embeds this URL at
# build time (PUBLIC_ASK_ENDPOINT).
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

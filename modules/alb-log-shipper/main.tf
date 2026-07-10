# modules/alb-log-shipper/main.tf

# =============================================================================
# ALB access-log -> Axiom shipper (Lambda)
#
# The deployment half of the visitor-source telemetry pipeline (solidago#108).
# betula owns the reusable, unit-tested S3->Axiom shipper package
# (lentago/betula clients/aws/alb-logs/alb_shipper); this module packages that
# package -- fetched at a PINNED ref, never duplicated into solidago -- as a
# Python 3.12 Lambda and wires it to the ALB access-logs bucket from module.alb
# (solidago#107):
#
#   ALB --(access logs)--> S3 bucket --ObjectCreated--> Lambda --> Axiom
#                                                        (gunzip -> parse -> ndjson POST)
#
# The Lambda handler is betula's alb_shipper.handler.lambda_handler verbatim.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name          = "${var.project}-${var.environment}-alb-log-shipper"
  bucket_arn    = "arn:${data.aws_partition.current.partition}:s3:::${var.access_logs_bucket}"
  log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name}"
}

# --- Package betula's shipper at a pinned ref --------------------------------
# build.sh fetches lentago/betula@var.betula_ref and vendors
# clients/aws/alb-logs/alb_shipper/ into build/vendor/. It re-runs only when the
# ref (or the script) changes. The package is standard-library-only and boto3
# ships in the Lambda runtime, so nothing is pip-installed -- the zip is just
# the source tree, with alb_shipper/ at the root so the handler resolves as
# alb_shipper.handler.lambda_handler.
resource "null_resource" "build" {
  triggers = {
    betula_repo = var.betula_repo
    betula_ref  = var.betula_ref
    build_sha   = filemd5("${path.module}/build.sh")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/build.sh"

    environment = {
      BETULA_REPO = var.betula_repo
      BETULA_REF  = var.betula_ref
      VENDOR_DIR  = "${path.module}/build/vendor"
    }
  }
}

# depends_on defers the archive to apply time, so a clean checkout (where
# build/vendor/ does not yet exist) plans without a "source_dir not found"
# error -- the null_resource vendors the package first, then this zips it.
data "archive_file" "this" {
  type        = "zip"
  source_dir  = "${path.module}/build/vendor"
  output_path = "${path.module}/build/alb_shipper.zip"

  depends_on = [null_resource.build]
}

# --- Axiom token: injected into the Lambda env at deploy time ----------------
# betula's shipper (alb_shipper/axiom.py) reads a BARE token from the
# AXIOM_API_TOKEN env var and builds the "Bearer <token>" header itself. AWS
# Lambda has no ECS-style `valueFrom` secret indirection for env vars, so the
# secret's current value is resolved here and set on the function. The secret
# is populated out-of-band (modules/secrets); picking up a rotated value is a
# re-apply (mirrors the ECS "new value, then redeploy" flow).
data "aws_secretsmanager_secret_version" "axiom_token" {
  secret_id = var.axiom_token_secret_arn
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

data "aws_iam_policy_document" "this" {
  # Read only the ALB log objects: the log bucket, under the log prefix only.
  statement {
    sid       = "ReadAlbLogObjects"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/${var.access_logs_prefix}/*"]
  }

  # Read the Axiom ingest token from exactly one secret. The token is injected
  # into the env above; this scoped grant keeps parity with the fleet's
  # execution-role secret pattern and supports rotation without widening scope.
  # The ":*" suffix covers Secrets Manager's version-id qualifier.
  statement {
    sid     = "ReadAxiomToken"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.axiom_token_secret_arn,
      "${var.axiom_token_secret_arn}:*",
    ]
  }

  # Write to the function's own CloudWatch log group only (pre-created below).
  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.log_group_arn}:*"]
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
  runtime       = "python3.12"
  handler       = "alb_shipper.handler.lambda_handler"

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_size

  environment {
    variables = {
      AXIOM_DATASET   = var.axiom_dataset
      AXIOM_API_TOKEN = data.aws_secretsmanager_secret_version.axiom_token.secret_string
    }
  }

  # Ensure the retained log group exists before the function writes to it.
  depends_on = [
    aws_iam_role_policy.this,
    aws_cloudwatch_log_group.this,
  ]

  tags = {
    Name = local.name
  }
}

# --- S3 ObjectCreated notification -------------------------------------------
# Permit S3 to invoke the function. source_account guards against the
# confused-deputy case where another account's bucket shares the name.
resource "aws_lambda_permission" "allow_s3" {
  statement_id   = "AllowInvokeFromAlbLogsBucket"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = local.bucket_arn
  source_account = data.aws_caller_identity.current.account_id
}

# A bucket supports exactly one aws_s3_bucket_notification; module.alb (#107)
# creates none, so this is the sole notification on the ALB-logs bucket -- no
# conflict. Filtered to the log prefix so only ALB log objects fan in.
resource "aws_s3_bucket_notification" "this" {
  bucket = var.access_logs_bucket

  lambda_function {
    lambda_function_arn = aws_lambda_function.this.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "${var.access_logs_prefix}/"
  }

  # S3 validates invoke permission when the notification is created.
  depends_on = [aws_lambda_permission.allow_s3]
}

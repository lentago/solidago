# modules/iam/main.tf

# =============================================================================
# ECS TASK EXECUTION ROLE
# 
# Assumed by the ECS control plane (not your app). Grants permission to:
#   - Pull images from ECR
#   - Write logs to CloudWatch
#   - Read secrets from Secrets Manager (for env var injection)
#   - Decrypt using our KMS key (because the secrets are encrypted)
#
# AWS provides a managed policy (AmazonECSTaskExecutionRolePolicy) that
# covers ECR pulls and CloudWatch logs. We attach that, then add a custom
# policy for Secrets Manager + KMS access. This is the least-privilege
# pattern: use the managed policy for the common stuff, custom policy
# for the specific stuff.
# =============================================================================

# --- Trust policy: who can assume this role? ---
# The "assume role policy" is the trust relationship. It says "only the
# ECS service principal can assume this role." This prevents any IAM user
# or other service from borrowing these permissions.
data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project}-${var.environment}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = {
    Name = "${var.project}-${var.environment}-ecs-task-execution"
  }
}

# Attach the AWS managed policy for baseline ECR + CloudWatch Logs access
resource "aws_iam_role_policy_attachment" "ecs_task_execution_base" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom policy for Secrets Manager + KMS access
data "aws_iam_policy_document" "ecs_task_execution_custom" {
  # Allow reading the specific database credentials secret.
  # Note: we're scoping to the exact secret ARN, not "all secrets."
  # The wildcard at the end covers secret version IDs, which Secrets
  # Manager appends (e.g., secret-arn:version-id:version-stage).
  statement {
    sid = "SecretsManagerRead"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = concat(
      [
        var.db_credentials_secret_arn,
        "${var.db_credentials_secret_arn}:*",
      ],
      var.rds_managed_secret_access ? [
        "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:rds!*",
      ] : [],
      # Additional secrets the execution role may read (e.g. the FireLens ->
      # Axiom ingest header). Passed as exact ARNs; ":*" suffixes cover
      # version-id qualifiers, matching the db-credentials pattern above.
      var.additional_execution_secret_arns,
      [for arn in var.additional_execution_secret_arns : "${arn}:*"]
    )
  }

  # Allow decrypting with our KMS key (needed because the secret is
  # encrypted with our CMK, not the default AWS-managed key).
  statement {
    sid = "KMSDecrypt"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "ecs_task_execution_custom" {
  name   = "${var.project}-${var.environment}-ecs-exec-secrets"
  policy = data.aws_iam_policy_document.ecs_task_execution_custom.json

  tags = {
    Name = "${var.project}-${var.environment}-ecs-exec-secrets"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_custom" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_task_execution_custom.arn
}


# =============================================================================
# ECS TASK ROLE
#
# Assumed by YOUR APPLICATION CODE running inside the container. This is
# where you grant whatever AWS access the app needs at runtime.
#
# Right now we don't know what the app will do, so we start with a minimal
# role — just the trust policy allowing ECS tasks to assume it. We'll add
# permissions as the application takes shape.
#
# The important thing is that the role EXISTS and is wired into the task
# definition from day one. Adding permissions later is easy; retrofitting
# a role into a running service is annoying.
# =============================================================================

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project}-${var.environment}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json

  tags = {
    Name = "${var.project}-${var.environment}-ecs-task"
  }
}

# Minimal app-level permissions. The app might need to read from S3,
# publish to SNS, etc. — we'll add those as the app is defined.
# For now, we grant read access to the same secrets (the app may need
# to read credentials at runtime, not just at task startup via env vars).
data "aws_iam_policy_document" "ecs_task_custom" {
  statement {
    sid = "SecretsManagerRead"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = concat(
      [
        var.db_credentials_secret_arn,
        "${var.db_credentials_secret_arn}:*",
      ],
      var.rds_managed_secret_access ? [
        "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:rds!*",
      ] : []
    )
  }

  statement {
    sid = "KMSDecrypt"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "ecs_task_custom" {
  name   = "${var.project}-${var.environment}-ecs-task-app"
  policy = data.aws_iam_policy_document.ecs_task_custom.json

  tags = {
    Name = "${var.project}-${var.environment}-ecs-task-app"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_custom" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task_custom.arn
}


# =============================================================================
# GITHUB ACTIONS OIDC ROLE
#
# This is the authentication mechanism for CI/CD. Instead of storing AWS
# access keys as GitHub secrets (which can leak, don't auto-rotate, and
# give you no way to scope by branch or repo), we use OpenID Connect.
#
# How it works:
# 1. GitHub Actions generates a short-lived JWT token for each workflow run
# 2. The token includes claims: which repo, which branch, which workflow
# 3. AWS has an OIDC identity provider that trusts GitHub's token issuer
# 4. The trust policy on this role says "accept tokens from GitHub, but
#    ONLY from this specific repo" (and optionally, only from main branch)
# 5. GitHub Actions calls sts:AssumeRoleWithWebIdentity with the JWT
# 6. AWS validates the token, checks the trust policy, and issues
#    temporary credentials that last for the workflow run
#
# The result: no long-lived credentials anywhere. Each workflow run gets
# fresh, short-lived creds scoped to exactly what the role allows.
# =============================================================================

# The OIDC provider is an account-level resource — you only need one,
# regardless of how many repos or roles use it. It tells AWS "I trust
# tokens issued by token.actions.githubusercontent.com."
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint for GitHub's OIDC provider. AWS requires this but as of
  # 2023, AWS actually ignores it for OIDC providers that use a trusted
  # root CA (which GitHub does). We include a placeholder that AWS accepts.
  # See: https://github.com/aws-actions/configure-aws-credentials/issues/357
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]

  tags = {
    Name = "${var.project}-github-oidc-provider"
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # This condition is CRITICAL for security. Without it, any GitHub
    # repo in the world could assume this role. The "sub" claim in
    # GitHub's JWT contains the repo and ref info. Each platform-hosted
    # workload repo (the app + any additional sites) is listed explicitly;
    # nothing else can assume the role.
    #
    # Subjects are pinned to the repo's default branch
    # (ref:refs/heads/main) rather than a wildcard ":*" ref, matching the
    # tighter precedent set by the Terraform pipeline role below. Every
    # site's deploy.yml runs only on push-to-main and workflow_dispatch,
    # and both issue a ref:refs/heads/main sub, so this covers all real
    # triggers. No wildcards remain, so we use StringEquals (a list is
    # OR-matched — a token matching any one entry is admitted).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # An entry may be a bare repo name (assumed under var.github_org) or an
      # owner-qualified "owner/repo" for a repo hosted outside the org (e.g. a
      # personal-account repo, or the immutable "owner@id/repo@id" form). The
      # owner portion is used verbatim; every entry is pinned to :ref:refs/heads/main.
      values = [
        for repo in concat([var.app_github_repo], var.additional_app_github_repos) :
        strcontains(repo, "/") ? "repo:${repo}:ref:refs/heads/main" : "repo:${var.github_org}/${repo}:ref:refs/heads/main"
      ]
    }

    # Audience check — the JWT must be intended for AWS STS
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-${var.environment}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  # Max session duration for GitHub Actions workflows.
  # 1 hour is usually plenty; long-running Terraform applies might
  # need more, but you can increase this later.
  max_session_duration = 3600

  tags = {
    Name = "${var.project}-${var.environment}-github-actions"
  }
}

# GitHub Actions needs broad-ish permissions because it runs Terraform
# (which creates/modifies/destroys infrastructure) and deploys to ECS.
# In a real org, you'd scope this more tightly — perhaps separate roles
# for "terraform plan" (read-only) vs "terraform apply" (write).
# For the lab, we give it the permissions it needs for Phases 3-7.
data "aws_iam_policy_document" "github_actions" {
  # ECS deployment permissions
  statement {
    sid = "ECSDeployment"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"] # ECS doesn't support resource-level permissions well
  }

  # ECR permissions for pushing images
  statement {
    sid = "ECRAccess"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"] # GetAuthorizationToken doesn't support resource scoping
  }

  statement {
    sid = "ECRRepoPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      # DescribeImages: read-only; the site-deploy reusable resolves the pushed
      # image's digest for build-provenance attestation (attest what the
      # REGISTRY has, not what the local daemon says). Added 2026-08-17 when
      # the first attested deploy failed AccessDenied on exactly this call.
      "ecr:DescribeImages",
    ]
    # Scoped to our account's ECR repos — we'll tighten to a specific repo
    # once we create it in Phase 3
    resources = ["arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"]
  }

  # IAM PassRole — required so GitHub Actions can tell ECS "use this role
  # for the task." Without PassRole, the deploy would fail with an
  # authorization error when registering the new task definition.
  statement {
    sid     = "IAMPassRole"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_task_execution.arn,
      aws_iam_role.ecs_task.arn,
    ]
  }

  # Terraform state access — needs to read/write the S3 backend
  statement {
    sid = "TerraformStateS3"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}",
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/*",
    ]
  }

  # The state bucket is encrypted with a dedicated, bootstrap-managed CMK
  # (alias/solidago-tfstate). Reading state requires kms:Decrypt; writing it
  # requires kms:GenerateDataKey (S3 SSE-KMS derives a per-object data key).
  # Scoped to that key only — this role gets no access to the platform's
  # main encryption key. The Terraform pipeline role already holds kms:* and
  # so is covered without a separate statement.
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

}

resource "aws_iam_policy" "github_actions" {
  name   = "${var.project}-${var.environment}-github-actions"
  policy = data.aws_iam_policy_document.github_actions.json

  tags = {
    Name = "${var.project}-${var.environment}-github-actions"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}


# =============================================================================
# GITHUB ACTIONS TERRAFORM PIPELINE ROLE
#
# A separate role for the Terraform infrastructure pipeline (terraform.yml),
# distinct from the app deploy role above. This role has broad infrastructure
# management permissions because Terraform needs to create/modify/destroy
# AWS resources across many services.
#
# Security boundary: OIDC trust is scoped to the 'terraform' GitHub
# environment, so only workflows running with `environment: terraform`
# can assume this role. This separates infrastructure management
# permissions from app deploy permissions (blast radius reduction).
# =============================================================================

data "aws_iam_policy_document" "github_actions_terraform_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:terraform"]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform" {
  name               = "${var.project}-${var.environment}-github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_actions_terraform_assume.json

  max_session_duration = 3600

  tags = {
    Name = "${var.project}-${var.environment}-github-actions-terraform"
  }
}

# trivy:ignore:AVD-AWS-0345 — the Terraform CI role manages ~20 services and
# grants `<service>:*` on each by design; trivy singles out `s3:*`. Genuine
# least-privilege for this role (or a read-only plan / write apply split) is
# tracked in #180 item 2 — not something to half-fix from a lint pass.
#trivy:ignore:AVD-AWS-0345
data "aws_iam_policy_document" "github_actions_terraform" {
  statement {
    sid    = "TerraformInfraManagement"
    effect = "Allow"

    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "ecr:*",
      "lambda:*",
      "rds:*",
      "elasticache:*",
      "route53:*",
      "acm:*",
      "iam:*",
      "kms:*",
      "cloudwatch:*",
      "logs:*",
      "cloudtrail:*",
      "sns:*",
      "config:*",
      "s3:*",
      "secretsmanager:*",
      "budgets:*",
      "wafv2:*",
      "waf-regional:*",
      "application-autoscaling:*",
    ]

    resources = ["*"]
  }

  statement {
    sid       = "CallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_actions_terraform" {
  name   = "${var.project}-${var.environment}-github-actions-terraform"
  policy = data.aws_iam_policy_document.github_actions_terraform.json

  tags = {
    Name = "${var.project}-${var.environment}-github-actions-terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = aws_iam_policy.github_actions_terraform.arn
}


# =============================================================================
# .GITHUB REPO TERRAFORM PIPELINE ROLE
#
# lentago/.github (the org's shared-workflows repo) is standing up its own
# Terraform-managed state (R19 step 1, lentago/.github#81). This role is
# scoped to exactly that repo's state key in solidago's shared tfstate
# bucket, plus the shared lock table — it cannot touch solidago's own state,
# any other repo's state, or any other AWS service. No GitHub-side
# permissions are granted here; those flow through a separate PAT secret in
# that repo's own CI, not this AWS role.
#
# Trust deliberately does NOT reuse the environment-gated shape of the
# github_actions_terraform role above. Instead it mirrors drosera's
# terraform.yml, which assumes a single Terraform-pipeline role from BOTH its
# plan job (triggered on pull_request) and its apply job (triggered on push
# to main) — see
# arn:aws:iam::365184644049:role/homelab-observability-github-actions-terraform.
# The trust condition below is a list of two subs, OR-matched by
# StringEquals (same technique as github_actions_assume above): the
# push-to-main sub for apply, and the fixed pull_request sub GitHub issues
# for any PR-triggered run regardless of head branch, for plan.
# =============================================================================

data "aws_iam_policy_document" "dotgithub_github_actions_terraform_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # lentago/.github is an established repo, not a freshly-created one, so
    # it issues the plain "repo:org/repo:..." sub form rather than GitHub's
    # newer immutable numeric-ID form (contrast the
    # lentago@<id>/site-pondviewlane-com@<id> entry above, which trusts a
    # genuinely new repo).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.dotgithub_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.dotgithub_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "dotgithub_github_actions_terraform" {
  name               = "dotgithub-github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.dotgithub_github_actions_terraform_assume.json

  max_session_duration = 3600

  tags = {
    Name = "dotgithub-github-actions-terraform"
  }
}

# Least privilege per lentago/.github#81: only this repo's state object in
# the shared tfstate bucket, plus the DynamoDB lock table. No ListBucket, no
# DeleteObject, no access to any other AWS service.
data "aws_iam_policy_document" "dotgithub_github_actions_terraform" {
  statement {
    sid = "TerraformStateS3"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/dotgithub/terraform.tfstate",
    ]
  }

  # The state bucket is encrypted with the dedicated bootstrap-managed CMK
  # (alias/solidago-tfstate). Its key policy delegates authorization entirely
  # to IAM (see scripts/bootstrap/bootstrap-backend.sh), so this grant is a
  # prerequisite for the S3 Get/Put above to actually succeed, not a
  # separate permission — same TerraformStateKMS pattern the app deploy role
  # above uses for its own state key.
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
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/solidago-tfstate-lock",
    ]
  }

  statement {
    sid       = "CallerIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "dotgithub_github_actions_terraform" {
  name   = "dotgithub-github-actions-terraform"
  policy = data.aws_iam_policy_document.dotgithub_github_actions_terraform.json

  tags = {
    Name = "dotgithub-github-actions-terraform"
  }
}

resource "aws_iam_role_policy_attachment" "dotgithub_github_actions_terraform" {
  role       = aws_iam_role.dotgithub_github_actions_terraform.name
  policy_arn = aws_iam_policy.dotgithub_github_actions_terraform.arn
}

# =============================================================================
# BETULA REPO TERRAFORM PIPELINE ROLE
#
# lentago/betula is bringing the Axiom side of its log archive (datasets,
# retention, ingest tokens) under Terraform (lentago/betula#118). This role
# gives betula's CI exactly what the dotgithub role above gives lentago/.github:
# read/write on its own state key in solidago's shared tfstate bucket, the
# tfstate CMK, and the shared lock table. It cannot read solidago's own state,
# any other repo's state, or any other AWS service; the Axiom provider
# authenticates with an Axiom token held as a betula repo secret, not via AWS.
#
# Trust mirrors the dotgithub role: the push-to-main sub for apply, plus the
# fixed pull_request sub for plan. betula is an established (renamed) repo, so
# it issues the plain "repo:org/repo:..." sub form.
# =============================================================================

data "aws_iam_policy_document" "betula_github_actions_terraform_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
        "repo:${var.github_org}/${var.betula_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.betula_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "betula_github_actions_terraform" {
  name               = "betula-github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.betula_github_actions_terraform_assume.json

  max_session_duration = 3600

  tags = {
    Name = "betula-github-actions-terraform"
  }
}

# Least privilege, same shape as the dotgithub role: this repo's state object,
# the tfstate CMK (the bucket's key policy delegates to IAM), and the lock table.
data "aws_iam_policy_document" "betula_github_actions_terraform" {
  statement {
    sid = "TerraformStateS3"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/betula/terraform.tfstate",
    ]
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
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/solidago-tfstate-lock",
    ]
  }

  statement {
    sid       = "CallerIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "betula_github_actions_terraform" {
  name   = "betula-github-actions-terraform"
  policy = data.aws_iam_policy_document.betula_github_actions_terraform.json

  tags = {
    Name = "betula-github-actions-terraform"
  }
}

resource "aws_iam_role_policy_attachment" "betula_github_actions_terraform" {
  role       = aws_iam_role.betula_github_actions_terraform.name
  policy_arn = aws_iam_policy.betula_github_actions_terraform.arn
}

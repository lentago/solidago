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
    sid    = "SecretsManagerRead"
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
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]

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
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for repo in concat([var.app_github_repo], var.additional_app_github_repos) :
        "repo:${var.github_org}/${repo}:*"
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
    resources = ["*"]  # ECS doesn't support resource-level permissions well
  }

  # ECR permissions for pushing images
  statement {
    sid = "ECRAccess"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]  # GetAuthorizationToken doesn't support resource scoping
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
    ]
    # Scoped to our account's ECR repos — we'll tighten to a specific repo
    # once we create it in Phase 3
    resources = ["arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"]
  }

  # IAM PassRole — required so GitHub Actions can tell ECS "use this role
  # for the task." Without PassRole, the deploy would fail with an
  # authorization error when registering the new task definition.
  statement {
    sid       = "IAMPassRole"
    actions   = ["iam:PassRole"]
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
      "arn:aws:s3:::foundry-tfstate-${var.aws_account_id}",
      "arn:aws:s3:::foundry-tfstate-${var.aws_account_id}/*",
    ]
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

data "aws_iam_policy_document" "github_actions_terraform" {
  statement {
    sid    = "TerraformInfraManagement"
    effect = "Allow"

    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "ecr:*",
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

# modules/iam/main.tf

# =============================================================================
# ECS TASK EXECUTION ROLE
# 
# Assumed by the ECS control plane (not your app). Grants permission to:
#   - Pull images from ECR
#   - Write logs to CloudWatch
#   - Read the exact secrets a task definition injects at container start
#     (today only the FireLens -> Axiom ingest header)
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
  # Read only the secrets a task definition injects (secrets / secretOptions),
  # passed as exact ARNs: today the FireLens -> Axiom ingest header. The ":*"
  # suffixes cover the version-id qualifiers Secrets Manager accepts
  # (secret-arn:version-id:version-stage).
  #
  # No database secret (#242): every service on these shared roles is a static
  # nginx site, and no task definition injects the RDS master secret or the
  # unused db-credentials placeholder, so the former rds!* wildcard and
  # db-credentials grants are gone. A future service that does use the
  # database gets its own task and execution roles, scoped to
  # module.rds.master_user_secret_arn alone (the per-service split in #237),
  # not a grant back on these shared ones.
  dynamic "statement" {
    for_each = length(var.additional_execution_secret_arns) > 0 ? [1] : []
    content {
      sid     = "SecretsManagerRead"
      actions = ["secretsmanager:GetSecretValue"]
      resources = concat(
        var.additional_execution_secret_arns,
        [for arn in var.additional_execution_secret_arns : "${arn}:*"],
      )
    }
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
#
# No secret read (#242). The task role used to read the db-credentials
# placeholder and every RDS-managed rds!* secret in the account, but no
# service on it reads a secret at runtime: all three are static nginx sites,
# and every site shares this role, so the grant reached any container in any
# site. The KMS statement below is now unused as well; it, and the matching
# AllowServiceRoleUsage entry in the main key's policy (modules/kms), go with
# the per-service task roles in #237 rather than piecemeal here.
data "aws_iam_policy_document" "ecs_task_custom" {
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

# The app deploy role pushes images and rolls ECS services; it runs no
# Terraform. Terraform runs on the separate pipeline role below (#55 split), so
# this role holds no grant on the state bucket or the state key. The state
# grants it once held were removed in #229, after IAM Access Advisor and
# CloudTrail showed no S3 or KMS use by the role and no trusted caller's
# workflow (all on shared-workflows site-deploy.yml) touches state.
#
# That keeps state out of reach only while the roles it can pass (PassRole
# below: the shared ECS task and execution roles) hold no state grant either:
# a trusted repo can ship code that runs under the task role. The wider
# cross-site reach of this one shared role is #237.
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
# This is the APPLY (write) role. Since #225/#156 the pipeline is split by
# GitHub environment: the plan job runs in `terraform-plan` and assumes the
# read-only github_actions_terraform_plan role below; only the apply job
# (push to main / workflow_dispatch on main) runs in `terraform` and assumes
# this one. This separates infrastructure management permissions from app
# deploy permissions (blast radius reduction), and keeps write credentials
# out of PR runs.
#
# Trust is the sub GitHub mints for a job that declares `environment:
# terraform`. The sub carries no ref, so IAM cannot tell main from a branch;
# the guard is the environment's deployment branch policy (main only, admins
# cannot bypass), which is repo configuration a PR cannot weaken. It is set
# once no plan uses the environment and codified in lentago/.github#311 (see
# README "Terraform CI roles: plan vs apply"). Deliberately NOT the bare
# ref:refs/heads/main sub: every main-context job with id-token: write mints
# that one, including claude.yml's comment-triggered responder.
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

# trivy:ignore:AVD-AWS-0345 — the Terraform APPLY role manages ~20 services
# and grants `<service>:*` on each by design; trivy singles out `s3:*`. #180
# item 2 was resolved by #225 as a plan/apply SPLIT, not per-resource least
# privilege: write credentials (including `s3:*`) live only on this role,
# which only main can assume: the `terraform` environment carries a main-only
# branch policy (#156). PR plans run on the read-only plan role below.
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

  # DynamoDB, scoped to this stack's own tables by name prefix rather than
  # listed with the services above. The first table is the Ask function's
  # durable daily cap (#241); the state lock is S3-native and needs none.
  # Control plane only: the table lifecycle Terraform drives (create, update,
  # delete, TTL, backups setting, tags) plus Describe*/List* metadata reads,
  # which is what the provider's refresh calls (DescribeTable,
  # DescribeTimeToLive, DescribeContinuousBackups, ListTagsOfResource, per
  # CloudTrail). No item reads or writes, no backup, restore, import or export:
  # the apply has no business with the rows.
  statement {
    sid    = "StackDynamoDBTables"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:UpdateTable",
      "dynamodb:DeleteTable",
      "dynamodb:Describe*",
      "dynamodb:List*",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
    ]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.project}-${var.environment}-*",
    ]
  }

  # GuardDuty (#243): the detector's lifecycle and its protection-plan
  # settings, which the provider drives through UpdateDetector. A region holds
  # one detector per account, and its ID is generated, so the scope is this
  # account's detectors rather than a name prefix. Create and List take no
  # resource. Not granted: filters (which can auto-archive findings), IP and
  # threat-intel sets, publishing destinations, members and finding
  # actions; nothing here manages them. The service-linked roles GuardDuty
  # creates on enable come under iam:* above.
  statement {
    sid    = "GuardDutyDetectorCreate"
    effect = "Allow"
    actions = [
      "guardduty:CreateDetector",
      "guardduty:ListDetectors",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "GuardDutyDetector"
    effect = "Allow"
    actions = [
      "guardduty:GetDetector",
      "guardduty:UpdateDetector",
      "guardduty:DeleteDetector",
      "guardduty:TagResource",
      "guardduty:UntagResource",
      "guardduty:ListTagsForResource",
    ]
    resources = [
      "arn:aws:guardduty:${var.aws_region}:${var.aws_account_id}:detector/*",
    ]
  }

  # EventBridge (#243): rules on the default bus and their targets, limited to
  # this stack's name prefix. The first rule forwards GuardDuty findings to the
  # alert topic. Rule and target calls are all authorized on the rule ARN.
  statement {
    sid    = "StackEventBridgeRules"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DescribeRule",
      "events:DeleteRule",
      "events:EnableRule",
      "events:DisableRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTargetsByRule",
      "events:TagResource",
      "events:UntagResource",
      "events:ListTagsForResource",
    ]
    resources = [
      "arn:aws:events:${var.aws_region}:${var.aws_account_id}:rule/${var.project}-${var.environment}-*",
    ]
  }

  statement {
    sid       = "CallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # The apply job's post-apply "Check out-of-band secrets" step (#230, the #213
  # pattern) reads each hand-written SSM slot to confirm it holds a real value
  # on the platform CMK. It reads into memory and tests shape only; nothing is
  # stored or printed. kms:Decrypt and kms:DescribeKey are already covered by
  # kms:* above. DescribeParameters (to read the slot's
  # KeyId) has no resource-level scoping, and returns metadata only. The read
  # is on exactly the listed slots (var.out_of_band_secret_parameter_arns).
  dynamic "statement" {
    for_each = length(var.out_of_band_secret_parameter_arns) > 0 ? [1] : []
    content {
      sid       = "OutOfBandSecretCheck"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = var.out_of_band_secret_parameter_arns
    }
  }

  statement {
    sid       = "OutOfBandSecretDescribe"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
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
# GITHUB ACTIONS TERRAFORM PLAN ROLE (read-only)
#
# Assumed by terraform.yml's plan job on pull_request (#225, #156). Trust is
# the sub GitHub mints for a job that declares `environment: terraform-plan`,
# which only the plan job does. Not the bare pull_request sub: every PR job
# with id-token: write mints that one (claude.yml, claude-review.yml). The
# `terraform-plan` environment has no branch policy, because PR refs must
# reach it; a workflow edit on any branch can still declare it and get these
# credentials, never the apply role above. Fork PRs get no id-token at all.
# They cannot write, but they DO read this stack's secret values: refresh
# reads the Secrets Manager values, the state stores them, and
# ReadOnlyAccess returns Lambda environment variables (the ALB-log shipper's
# Axiom token among them). Treat this role as a secret-reading credential.
#
# Known residual: the shared state bucket uses an S3 Bucket Key, so the KMS
# encryption context is the bucket, not the object, and Decrypt on the state
# CMK cannot be narrowed to this stack's state. ReadOnlyAccess's s3:Get* then
# reaches the other stacks' state objects in the bucket. Tracked in #240.
#
# Permissions = AWS-managed ReadOnlyAccess (refresh reads across every
# service the stack uses) plus the few things a plan needs that it lacks:
#   - state: read env/dev/terraform.tfstate, and write/delete ONLY its
#     S3-native lockfile (backend.tf use_lockfile = true → <key>.tflock;
#     no DynamoDB table for this backend). A plan never writes state.
#   - the tfstate CMK: Decrypt to read state, GenerateDataKey for the
#     SSE-KMS lockfile PUT.
#   - secret VALUES: ReadOnlyAccess omits secretsmanager:GetSecretValue, but
#     refresh of aws_secretsmanager_secret_version (modules/secrets) and the
#     data source in modules/alb-log-shipper read them. Scoped to this
#     stack's own secrets; Decrypt on the main CMK only via Secrets Manager.
# An apply attempted under this role fails on the first mutating call.
# =============================================================================

data "aws_iam_policy_document" "github_actions_terraform_plan_assume" {
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
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:terraform-plan"]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform_plan" {
  name               = "${var.project}-${var.environment}-github-actions-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.github_actions_terraform_plan_assume.json

  max_session_duration = 3600

  tags = {
    Name = "${var.project}-${var.environment}-github-actions-terraform-plan"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_plan_readonly" {
  role       = aws_iam_role.github_actions_terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_actions_terraform_plan" {
  statement {
    sid     = "TerraformStateRead"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/env/${var.environment}/terraform.tfstate",
    ]
  }

  statement {
    sid       = "TerraformStateList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::solidago-tfstate-${var.aws_account_id}"]
  }

  statement {
    sid = "TerraformStateLock"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/env/${var.environment}/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid = "TerraformStateKMS"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.tfstate_kms_key_arn]
  }

  statement {
    sid     = "StackSecretValues"
    actions = ["secretsmanager:GetSecretValue"]
    # Both naming forms in modules/secrets: <project>-<env>/db-credentials and
    # <project>-<env>-axiom-*. RDS-managed rds!db-* secrets stay out of reach.
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project}-${var.environment}-*",
      "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project}-${var.environment}/*",
    ]
  }

  statement {
    sid       = "StackSecretDecrypt"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "github_actions_terraform_plan" {
  name   = "${var.project}-${var.environment}-github-actions-terraform-plan"
  policy = data.aws_iam_policy_document.github_actions_terraform_plan.json

  tags = {
    Name = "${var.project}-${var.environment}-github-actions-terraform-plan"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_plan" {
  role       = aws_iam_role.github_actions_terraform_plan.name
  policy_arn = aws_iam_policy.github_actions_terraform_plan.arn
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
# arn:aws:iam::365184644049:role/drosera-github-actions-terraform.
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
  # separate permission. Reading state requires kms:Decrypt; writing it
  # requires kms:GenerateDataKey (S3 SSE-KMS derives a per-object data key).
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

# =============================================================================
# DROSERA REPO TERRAFORM PIPELINE ROLE
#
# lentago/drosera keeps the state for its Grafana Cloud Terraform (dashboards,
# folders, alert rules) in solidago's shared tfstate bucket. This role gives
# drosera's CI exactly what the betula role above gives lentago/betula:
# read/write on its own state key, the tfstate CMK, and the shared lock table.
# It cannot read solidago's own state or any other AWS service; the Grafana
# provider authenticates with Grafana Cloud credentials held as drosera repo
# secrets, not via AWS. Of other repos' state it can read exactly one object,
# betula's (read-only, BetulaStateRead below), so drosera consumes Axiom tokens
# from betula's `axiom_tokens` output via terraform_remote_state
# (lentago/betula#119 option A; solidago#268).
#
# Phase 1 of lentago/drosera#169, which completes the homelab-observability ->
# drosera rename: drosera's CI and its state move onto this role and the
# drosera/ key in a later drosera-side cutover. The pre-rename role it replaces
# was created by hand outside Terraform and is retired separately.
#
# Trust mirrors the dotgithub and betula roles: the push-to-main sub for apply,
# plus the fixed pull_request sub for plan. drosera is an established (renamed)
# repo, so it issues the plain "repo:org/repo:..." sub form.
# =============================================================================

data "aws_iam_policy_document" "drosera_github_actions_terraform_assume" {
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
        "repo:${var.github_org}/${var.drosera_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.drosera_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "drosera_github_actions_terraform" {
  name               = "drosera-github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.drosera_github_actions_terraform_assume.json

  max_session_duration = 3600

  tags = {
    Name = "drosera-github-actions-terraform"
  }
}

# Least privilege, same shape as the dotgithub and betula roles: this repo's
# state object, the tfstate CMK (the bucket's key policy delegates to IAM), and
# the lock table.
data "aws_iam_policy_document" "drosera_github_actions_terraform" {
  statement {
    sid = "TerraformStateS3"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/drosera/terraform.tfstate",
    ]
  }

  # Read-only on betula's state key, for a terraform_remote_state read of its
  # axiom_tokens output (lentago/betula#119 option A; solidago#268). A remote
  # state read never writes and never takes the lock, so: GetObject only, no
  # PutObject, no lock-table or .tflock grant, no ListBucket. Decrypt comes
  # from TerraformStateKMS below. With the bucket's S3 Bucket Key enabled the
  # KMS grant cannot be scoped per object (#240), so this resource is the only
  # per-key boundary: keep it to this one key.
  statement {
    sid       = "BetulaStateRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::solidago-tfstate-${var.aws_account_id}/betula/terraform.tfstate"]
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

resource "aws_iam_policy" "drosera_github_actions_terraform" {
  name   = "drosera-github-actions-terraform"
  policy = data.aws_iam_policy_document.drosera_github_actions_terraform.json

  tags = {
    Name = "drosera-github-actions-terraform"
  }
}

resource "aws_iam_role_policy_attachment" "drosera_github_actions_terraform" {
  role       = aws_iam_role.drosera_github_actions_terraform.name
  policy_arn = aws_iam_policy.drosera_github_actions_terraform.arn
}

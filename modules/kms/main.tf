# modules/kms/main.tf

# =============================================================================
# KMS Customer-Managed Key (CMK)
# 
# A single key used to encrypt: RDS, S3, Secrets Manager, CloudWatch Logs,
# and ECS/EBS storage. One key keeps the lab simple and costs $1/month.
#
# KEY POLICY PRIMER:
# Unlike most AWS resources where IAM policies are sufficient, KMS has its own
# resource-based policy (the "key policy") that acts as the FIRST gate.
# Even if an IAM policy says "allow kms:Decrypt", if the key policy doesn't
# also permit it, the call is denied. Think of it as a two-lock system:
# both the key policy AND the IAM policy must say "yes."
#
# The exception: if the key policy grants access to the root principal,
# then IAM policies alone can authorize access. This is the standard pattern
# and the one we're using — the root statement is your safety net.
# =============================================================================

resource "aws_kms_key" "this" {
  description             = "${var.project}-${var.environment} main encryption key"
  deletion_window_in_days = 30   # Safety net — key isn't actually deleted for 30 days
  enable_key_rotation     = true # Automatic annual rotation. No reason not to.

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${var.project}-${var.environment}-key-policy"
    Statement = concat(
      [
        # -----------------------------------------------------------------
        # Statement 1: Root account access (THE ESCAPE HATCH)
        # 
        # This is non-negotiable. Without this statement, if you delete or
        # misconfigure the other policy statements, you lose all access to
        # the key — and everything encrypted with it. AWS Support can't
        # help you. The data is gone. This single statement prevents that
        # nightmare by ensuring IAM policies in the account can always
        # grant access to the key.
        # -----------------------------------------------------------------
        {
          Sid    = "EnableRootAccountAccess"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${var.aws_account_id}:root"
          }
          Action   = "kms:*"
          Resource = "*" # In a key policy, "*" means "this key" — not all keys
        },

        # -----------------------------------------------------------------
        # Statement 2: Key administrators
        # 
        # Can manage the key (describe, enable/disable, update policy, 
        # schedule deletion) but NOT use it to encrypt/decrypt data.
        # Separation of duties: admins manage keys, services use keys.
        # -----------------------------------------------------------------
        {
          Sid    = "AllowKeyAdministration"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${var.aws_account_id}:root"
          }
          Action = [
            "kms:Create*",
            "kms:Describe*",
            "kms:Enable*",
            "kms:List*",
            "kms:Put*",
            "kms:Update*",
            "kms:Revoke*",
            "kms:Disable*",
            "kms:Get*",
            "kms:Delete*",
            "kms:TagResource",
            "kms:UntagResource",
            "kms:ScheduleKeyDeletion",
            "kms:CancelKeyDeletion"
          ]
          Resource = "*"
        },

        # -----------------------------------------------------------------
        # Statement 3: CloudWatch Logs service principal
        #
        # CloudWatch Logs is special — it operates as a service principal
        # (logs.us-east-1.amazonaws.com), not via an IAM role you control.
        # It needs explicit key policy permission because you can't attach
        # an IAM policy to an AWS service. The condition scopes this to
        # only log groups in YOUR account, preventing cross-account abuse.
        # -----------------------------------------------------------------
        {
          Sid    = "AllowCloudWatchLogs"
          Effect = "Allow"
          Principal = {
            Service = "logs.${var.aws_region}.amazonaws.com"
          }
          Action = [
            "kms:Encrypt*",
            "kms:Decrypt*",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:Describe*"
          ]
          Resource = "*"
          Condition = {
            ArnLike = {
              "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:*"
            }
          }
        },

        # -----------------------------------------------------------------
        # Statement 4: CloudTrail service principal — encrypt
        #
        # CloudTrail needs GenerateDataKey* to encrypt log files before
        # delivering them to S3. The condition scopes this to trails in
        # THIS account only, preventing cross-account abuse.
        #
        # We intentionally don't use aws:SourceArn here because it would
        # create a circular dependency: the trail references the KMS key,
        # and the KMS key policy would reference the trail ARN. The
        # EncryptionContext condition is sufficient for single-account use.
        # -----------------------------------------------------------------
        {
          Sid    = "AllowCloudTrailEncrypt"
          Effect = "Allow"
          Principal = {
            Service = "cloudtrail.amazonaws.com"
          }
          Action   = "kms:GenerateDataKey*"
          Resource = "*"
          Condition = {
            StringLike = {
              "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${var.aws_account_id}:trail/*"
            }
          }
        },

        # -----------------------------------------------------------------
        # Statement 5: CloudTrail service principal — describe
        #
        # CloudTrail calls DescribeKey to verify the key exists and is
        # usable before attempting encryption. This is a read-only
        # metadata operation — no data access.
        # -----------------------------------------------------------------
        {
          Sid    = "AllowCloudTrailDescribeKey"
          Effect = "Allow"
          Principal = {
            Service = "cloudtrail.amazonaws.com"
          }
          Action   = "kms:DescribeKey"
          Resource = "*"
        }
      ],

      # -------------------------------------------------------------------
      # Statement 4 (conditional): Service role usage grants
      #
      # This is where ECS task execution roles, etc. get encrypt/decrypt.
      # We use concat() with a conditional so this statement only appears
      # when there are actually roles to grant access to. Empty policy
      # statements with no principals would be invalid JSON.
      # -------------------------------------------------------------------
      length(var.service_role_arns) > 0 ? [
        {
          Sid    = "AllowServiceRoleUsage"
          Effect = "Allow"
          Principal = {
            AWS = var.service_role_arns
          }
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey",
            "kms:Encrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*"
          ]
          Resource = "*"
        }
      ] : []
    )
  })

  tags = {
    Name = "${var.project}-${var.environment}-main-key"
  }
}

# An alias is a human-friendly name for the key. Without this, you'd
# reference the key everywhere by its ARN or key ID (a UUID), which is
# painful. The "alias/" prefix is required by AWS.
resource "aws_kms_alias" "this" {
  name          = "alias/${var.project}-${var.environment}-main"
  target_key_id = aws_kms_key.this.key_id
}

moved {
  from = aws_kms_key.main
  to   = aws_kms_key.this
}

moved {
  from = aws_kms_alias.main
  to   = aws_kms_alias.this
}

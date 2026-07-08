# Bootstrap Runbook

This guide walks through deploying the solidago stack (AWS resources and the Terraform state backend both use the `solidago-` prefix; the backend was migrated from `foundry-tfstate-*` to `solidago-tfstate-*` on 2026-07-08 per issue #103) from scratch. It covers every manual step required before Terraform can manage the environment autonomously.

**Audience:** Engineers evaluating this project, or anyone standing up their own instance of the stack.

**Time estimate:** ~45 minutes for a fresh AWS account with a registered domain.

---

## Prerequisites

- An AWS account with root/admin access
- A registered domain (this guide uses `icecreamtofightwith.com` as the example)
- [Terraform](https://developer.hashicorp.com/terraform/install) installed locally (or [tfswitch](https://tfswitch.warrensbox.com/) for version management)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with a named profile
- A GitHub account and the [GitHub CLI](https://cli.github.com/) installed
- Git configured with your identity

---

## Step 1: AWS Account Setup

If you're using an existing account, skip to Step 2.

1. Create an AWS account at https://aws.amazon.com
2. Enable MFA on the root user (Security Credentials → MFA)
3. Create an IAM user or SSO identity for day-to-day work — avoid using root

Configure the AWS CLI with a named profile:

```bash
aws configure --profile foundry
# Region: us-east-1
# Output: json
```

Verify access:

```bash
aws sts get-caller-identity --profile foundry
```

Note your **Account ID** from the output. You'll need it throughout this guide. The examples below use `<ACCOUNT_ID>` as a placeholder — replace with yours.

---

## Step 2: Create the Terraform State Backend

Terraform needs a remote backend before it can manage anything. These resources are intentionally created outside of Terraform (chicken-and-egg problem).

The `scripts/bootstrap/bootstrap-backend.sh` script performs all of these steps
(and is idempotent for the KMS key). The commands below are the equivalent
manual sequence:

```bash
export AWS_PROFILE=foundry
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# S3 bucket for state files
aws s3api create-bucket \
  --bucket "solidago-tfstate-${ACCOUNT_ID}" \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket "solidago-tfstate-${ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

# Dedicated CMK for the state bucket (separate from the Terraform-managed
# key — see the note below). Root-only key policy; IAM policies authorize
# the CI roles.
KEY_ID=$(aws kms create-key \
  --description "foundry Terraform state bucket encryption key" \
  --tags TagKey=Name,TagValue=solidago-tfstate-key \
  --policy '{
    "Version": "2012-10-17",
    "Id": "solidago-tfstate-key-policy",
    "Statement": [{
      "Sid": "EnableRootAccountAccess",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::'"${ACCOUNT_ID}"':root" },
      "Action": "kms:*",
      "Resource": "*"
    }]
  }' \
  --query 'KeyMetadata.KeyId' --output text)

aws kms enable-key-rotation --key-id "${KEY_ID}"
aws kms create-alias --alias-name alias/solidago-tfstate --target-key-id "${KEY_ID}"
KEY_ARN=$(aws kms describe-key --key-id "${KEY_ID}" --query 'KeyMetadata.Arn' --output text)

# Default the bucket to SSE-KMS using that CMK
aws s3api put-bucket-encryption \
  --bucket "solidago-tfstate-${ACCOUNT_ID}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "'"${KEY_ARN}"'"
      },
      "BucketKeyEnabled": true
    }]
  }'

aws s3api put-public-access-block \
  --bucket "solidago-tfstate-${ACCOUNT_ID}" \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'
```

State locking uses S3-native locking (`use_lockfile = true`, Terraform 1.10+). No DynamoDB table is needed.

> **Why a dedicated state CMK (`alias/solidago-tfstate`), not the Terraform-managed `alias/solidago-dev-main`?**
> The state bucket is bootstrapped *outside* Terraform (chicken-and-egg), so its
> key can't be a Terraform resource. Reusing the Terraform-managed key would be
> a circular dependency — that key is *defined in* the state stored in this
> bucket — and `terraform destroy` schedules it for deletion, which would lock
> you out of your own state on the next teardown. The dedicated key is never
> touched by Terraform, so it is always available. Its root-only key policy is
> the standard KMS escape hatch; the GitHub Actions roles get scoped
> `kms:Encrypt/Decrypt/GenerateDataKey/DescribeKey` on it via `modules/iam`.

> **Upgrading an existing AES256 backend?** After switching the bucket to
> SSE-KMS and adding `kms_key_id` to `backend.tf`, run
> `terraform init -reconfigure` in `environments/dev`. Existing state objects
> stay readable (their AES256 encryption is intact); only new writes use the
> CMK. This is a human-run step — the state bucket and its key are
> bootstrap-managed, not applied by the CI pipeline.

---

## Step 3: Clone the Repository

```bash
git clone https://github.com/lentago/solidago.git
cd solidago
```

---

## Step 4: Configure Variables

Review and update the Terraform variables for your environment:

```bash
cat environments/dev/terraform.tfvars
```

At minimum, update:
- `project` — your project name (default: `solidago`)
- `environment` — environment name (default: `dev`)
- `domain_name` — your registered domain
- Any resource sizing (RDS instance class, ElastiCache node type, etc.)

Update the backend configuration in `environments/dev/main.tf` to reference your state bucket:

```hcl
backend "s3" {
  bucket       = "solidago-tfstate-YOUR_ACCOUNT_ID"
  key          = "environments/dev/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true
  encrypt      = true
  kms_key_id   = "arn:aws:kms:us-east-1:YOUR_ACCOUNT_ID:alias/solidago-tfstate"
}
```

---

## Step 5: Initial Terraform Apply

This first apply runs from your local machine using your AWS CLI profile. It creates all infrastructure including the OIDC provider and app deploy IAM role.

```bash
cd environments/dev
export AWS_PROFILE=foundry

terraform init
terraform plan
terraform apply
```

This will take 10-15 minutes. Notable resources that take time: RDS instance, ElastiCache replication group, ACM certificate validation (if DNS isn't delegated yet).

**Save the outputs.** You'll need several values in the next steps:
- `route53_name_servers` — for DNS delegation
- `github_actions_role_arn` — for verifying OIDC setup

---

## Step 6: Delegate DNS

Point your domain's nameservers to the Route 53 hosted zone. At your domain registrar, set the NS records to the values from `route53_name_servers` output.

This is required for:
- ACM certificate validation (HTTPS)
- The ALB alias record (your domain → ALB)

DNS propagation can take up to 48 hours, but typically completes in under an hour. You can verify with:

```bash
dig NS yourdomain.com
```

---

## Step 7: Create the Terraform Pipeline IAM Role

The Terraform infrastructure pipeline uses a separate IAM role from the app deploy pipeline. This role is created manually, then imported into Terraform state.

### 7a. Create the OIDC trust policy

```bash
cat > /tmp/terraform-role-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/solidago:environment:terraform"
        }
      }
    }
  ]
}
EOF
```

Replace `YOUR_ACCOUNT_ID` and `YOUR_ORG` with your values.

### 7b. Create the permissions policy

```bash
cat > /tmp/terraform-role-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformInfraManagement",
      "Effect": "Allow",
      "Action": [
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
        "waf-regional:*",
        "wafv2:*",
        "application-autoscaling:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
EOF
```

### 7c. Create the role and attach the policy

```bash
aws iam create-role \
  --role-name solidago-dev-github-actions-terraform \
  --assume-role-policy-document file:///tmp/terraform-role-trust.json

aws iam create-policy \
  --policy-name solidago-dev-github-actions-terraform \
  --policy-document file:///tmp/terraform-role-policy.json

# Use the policy ARN from the create-policy output
aws iam attach-role-policy \
  --role-name solidago-dev-github-actions-terraform \
  --policy-arn "arn:aws:iam::YOUR_ACCOUNT_ID:policy/solidago-dev-github-actions-terraform"
```

### 7d. Import into Terraform

```bash
cd environments/dev

terraform import \
  module.iam.aws_iam_role.github_actions_terraform \
  solidago-dev-github-actions-terraform

terraform import \
  module.iam.aws_iam_policy.github_actions_terraform \
  "arn:aws:iam::YOUR_ACCOUNT_ID:policy/solidago-dev-github-actions-terraform"

terraform import \
  module.iam.aws_iam_role_policy_attachment.github_actions_terraform \
  "solidago-dev-github-actions-terraform/arn:aws:iam::YOUR_ACCOUNT_ID:policy/solidago-dev-github-actions-terraform"
```

Verify the import is clean:

```bash
terraform plan
# Expected: No changes (or unrelated pending changes)
```

---

## Step 8: Create the GitHub Environment

1. Go to your repo → Settings → Environments
2. Create a new environment named `terraform`
3. No protection rules needed — branch protection gates what reaches main

---

## Step 9: Configure Branch Protection

In your repo → Settings → Rules → Rulesets:

1. Create a new ruleset targeting the `main` branch
2. Enable **Require a pull request before merging**
3. Enable **Require status checks to pass** — add the `Terraform Plan` check
4. Enable **Block force pushes**

---

## Step 10: Verify the Pipelines

### Terraform pipeline

Create a test branch, make a trivial `.tf` change (add a comment), open a PR:

```bash
git checkout -b test/verify-pipeline
echo "# Pipeline verification" >> environments/dev/main.tf
git add -A && git commit -m "test: verify terraform pipeline"
git push origin test/verify-pipeline
```

Open the PR in GitHub. The Terraform Plan job should:
- Authenticate via OIDC to the `terraform` environment
- Run `terraform plan` successfully
- Post the plan output as a PR comment

Merge the PR. The Terraform Apply job should:
- Run `terraform apply -auto-approve`
- Complete with no changes

### App deploy pipeline

Push a change to a workload repo (e.g., `site-icecreamtofightwith-com`). Its own deploy workflow should assume the `solidago-dev-github-actions` role via OIDC, build the container, push it to ECR, and update the ECS service. Workload deploys run entirely from the workload repo — nothing is dispatched back into this repo.

---

## Step 11: Tear Down (When Done for the Day)

The most expensive resources are RDS, ElastiCache, NAT Gateways, and the ALB. To avoid overnight charges:

```bash
cd environments/dev
export AWS_PROFILE=foundry
terraform destroy
```

To bring it back up:

```bash
terraform apply
```

The Terraform state backend (S3) persists across destroy/apply cycles — you never lose your state.

---

## Cost Notes

Estimated monthly cost with all resources running 24/7:
- **NAT Gateways (x2):** ~$65
- **ALB:** ~$16 + data processing
- **RDS (db.t3.micro):** ~$15
- **ElastiCache (cache.t3.micro):** ~$12
- **ECS Fargate:** ~$10 (single task, minimal CPU/memory)
- **Route 53:** ~$0.50
- **WAF:** ~$8-9
- **Other (CloudTrail, Config, S3, KMS):** ~$5

**Total running 24/7:** ~$130-140/month

**With daily destroy/apply (evenings and weekends only):** Significantly less. NAT Gateways and ALB are the biggest line items and only charge when running.

Budget alerts are configured at 50%, 80%, and 100% of $100/month via SNS.

---

## Architecture Reference

See the [README](../README.md) for the architecture diagram and module descriptions.

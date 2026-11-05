# Bootstrap Runbook

This guide walks through deploying the solidago stack (AWS resources and the Terraform state backend both use the `solidago-` prefix; the backend was migrated from `foundry-tfstate-*` to `solidago-tfstate-*` on 2026-07-08 per issue #103) from scratch. It covers every manual step required before Terraform can manage the environment autonomously.

**Audience:** Engineers evaluating this project, or anyone standing up their own instance of the stack.

> **Adopting Solidago into your own AWS account?** [ADOPTION.md](../ADOPTION.md) is the front door — prerequisites, an intake table, an exhaustive swap list, and a local-first drill. This document is the detailed step reference it links into; read it alongside the drill.

**Time estimate:** ~45 minutes for a fresh AWS account with a registered domain.

---

## Prerequisites

- An AWS account with root/admin access
- A registered domain (this guide uses `icecreamtofightwith.com` as the example)
- [Terraform](https://developer.hashicorp.com/terraform/install) installed locally (or [tfswitch](https://tfswitch.warrensbox.com/) for version management)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with credentials
- A GitHub account and the [GitHub CLI](https://cli.github.com/) installed
- Git configured with your identity

---

## Step 1: AWS Account Setup

If you're using an existing account, skip to Step 2.

1. Create an AWS account at https://aws.amazon.com
2. Enable MFA on the root user (Security Credentials → MFA)
3. Create an IAM user or SSO identity for day-to-day work — avoid using root

Configure the AWS CLI with your credentials:

```bash
aws configure
# Region: us-east-1
# Output: json
```

Verify access:

```bash
aws sts get-caller-identity
```

If you prefer to use a named profile instead of the default credentials, pass `--profile <name>` to these commands and export `AWS_PROFILE=<name>` in your shell before running subsequent steps.

Note your **Account ID** from the output. You'll need it throughout this guide. The examples below use `<ACCOUNT_ID>` as a placeholder — replace with yours.

---

## Step 2: Create the Terraform State Backend

Terraform needs a remote backend before it can manage anything. These resources are intentionally created outside of Terraform (chicken-and-egg problem).

The `scripts/bootstrap/bootstrap-backend.sh` script performs all of these steps
(and is idempotent for the KMS key). The commands below are the equivalent
manual sequence:

```bash
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
  --description "solidago Terraform state bucket encryption key" \
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

Copy the example variables file and fill in your values:

```bash
cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
```

Open `environments/dev/terraform.tfvars` in your editor. Each variable has a comment explaining what it is and where to find the value. At minimum, set the preview hostnames:
- `lentago_preview_host` — an unguessable single-label subdomain of your primary domain (e.g. `my-secret-preview`)
- `pondview_preview_host` — a separate unguessable subdomain for the Pond View site preview

Variables with empty-string defaults (`grafana_cloud_account_id`, `grafana_cloud_external_id`) are optional — leave them blank to skip those integrations. The Ask Lambda's Anthropic key is deliberately not a variable: it is written out of band to an SSM SecureString so it never enters state (see [`modules/ask-lambda/main.tf`](../modules/ask-lambda/main.tf)). Variables with non-empty defaults (`project`, `environment`, `aws_region`) can be left as-is for a standard dev deployment.

Update the backend configuration in `environments/dev/backend.tf` to reference your state bucket:

```hcl
backend "s3" {
  bucket       = "solidago-tfstate-YOUR_ACCOUNT_ID"
  key          = "env/dev/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true
  encrypt      = true
  kms_key_id   = "arn:aws:kms:us-east-1:YOUR_ACCOUNT_ID:alias/solidago-tfstate"
}
```

---

## Step 5: Initial Terraform Apply

This first apply runs from your local machine using your AWS CLI profile. It creates all infrastructure, including the GitHub OIDC provider and both CI roles: the app deploy role and the Terraform pipeline role (verified in Step 7).

```bash
cd environments/dev

terraform init
terraform plan
terraform apply
```

This will take 10-15 minutes. Notable resources that take time: RDS instance, ElastiCache replication group, ACM certificate validation (if DNS isn't delegated yet).

**Save the outputs.** You'll need several values in the next steps:
- `route53_name_servers` — for DNS delegation
- `github_actions_role_arn` — the app deploy role, for your workload repositories' deploy workflows
- `github_actions_terraform_role_arn` — the Terraform pipeline role, for `.github/workflows/terraform.yml`

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

## Step 7: Verify the Terraform Pipeline IAM Role

The Terraform infrastructure pipeline uses two IAM roles, separate from the app deploy pipeline: the write role `<project>-<environment>-github-actions-terraform` for applies, and the read-only `<project>-<environment>-github-actions-terraform-plan` for PR plans (#225). `modules/iam` declares both roles, their policies and attachments, so **the first apply in Step 5 created them**. That apply ran from your machine with your own credentials, so nothing has to be made by hand and nothing needs `terraform import`. Do not create the role with the AWS CLI. If you do, the apply fails with `EntityAlreadyExists`, or, if you create it after the apply, the CLI fails.

Check that both roles exist and that their trust names your repository:

```bash
cd environments/dev

terraform output github_actions_terraform_role_arn

aws iam get-role \
  --role-name "$(terraform output -raw github_actions_terraform_role_arn | cut -d/ -f2)" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
# Expected: the sub condition is repo:YOUR_ORG/YOUR_REPO:environment:terraform

aws iam get-role \
  --role-name "$(terraform output -raw github_actions_terraform_plan_role_arn | cut -d/ -f2)" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
# Expected: the sub condition is repo:YOUR_ORG/YOUR_REPO:environment:terraform-plan
```

The `sub` comes from the `github_org` and `github_repo` inputs of `module.iam` in `environments/dev/main.tf`. If it names the wrong repository, fix those inputs and apply again. Then put the plan role's ARN in the plan job's `role-to-assume` line of `.github/workflows/terraform.yml`, and the write role's ARN in the apply job's (see the ADOPTION swap list).

---

## Step 8: Create the GitHub Environments

Each Terraform role trusts only the OIDC `sub` of one GitHub environment, so the environments are load-bearing for AWS access even though they hold no secrets or variables:

| Environment | Used by | Protection |
|---|---|---|
| `terraform-plan` | the plan job, on pull requests | none: pull-request refs must reach it |
| `terraform` | the apply job, on `main` | deployment branch policy: **`main` only**, and administrators **cannot** bypass it |

The branch policy on `terraform` is what keeps the write role on `main`. The role's `sub` carries no ref, so IAM cannot check the branch itself, and an `if:` in the workflow file is editable by any PR that touches it (#156). **Do this step before you push any branch other than `main`.** From the Step 5 apply on, the write role exists, and until the policy does, a workflow on any branch that declares `environment: terraform` can assume it. A workflow run auto-creates a missing environment with no protection. If `terraform` already exists when you reach this step, add the policy to it.

In your repo → Settings → Environments:

1. Create `terraform-plan`. Add no protection rules.
2. Create `terraform`. Under **Deployment branches and tags** choose **Selected branches and tags** and add the branch rule `main`. Leave **Allow administrators to bypass configured protection rules** unchecked.

Or with `gh`:

```bash
gh api -X PUT repos/YOUR_ORG/YOUR_REPO/environments/terraform-plan
gh api -X PUT repos/YOUR_ORG/YOUR_REPO/environments/terraform --input - <<'JSON'
{"can_admins_bypass": false,
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST repos/YOUR_ORG/YOUR_REPO/environments/terraform/deployment-branch-policies \
  -f name=main -f type=branch
```

If your organization manages repository settings as code, as Lentago does in `lentago/.github`, declare both environments and the policy there instead.

---

## Step 9: Configure Branch Protection

In your repo → Settings → Rules → Rulesets:

1. Create a new ruleset targeting the `main` branch
2. Enable **Require a pull request before merging**
3. Enable **Require status checks to pass** — add the `gate` check. Do not require `Terraform Plan` itself: it is skipped on PRs that change no Terraform, and a required check that never reports holds those PRs forever. `gate` runs on every PR and fails when the plan, or the `changes` job that decides whether a plan is needed, fails or is cancelled. Requiring it is what blocks a bad plan.
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
- Run in the `terraform-plan` environment and authenticate via OIDC as the read-only plan role (the `AWS caller identity` step names it)
- Run `terraform plan` successfully
- Post the plan output as a PR comment

Merge the PR. The Terraform Apply job should:
- Run in the `terraform` environment and authenticate as the write role (again named by `AWS caller identity`)
- Run `terraform apply -auto-approve`
- Complete with no changes

### App deploy pipeline

Push a change to a workload repo (e.g., `site-icecreamtofightwith-com`). Its own deploy workflow should assume the `solidago-dev-github-actions` role via OIDC, build the container, push it to ECR, and update the ECS service. Workload deploys run entirely from the workload repo — nothing is dispatched back into this repo.

---

## Step 11: Tear Down (When Done for the Day)

The most expensive resources are RDS, ElastiCache, NAT Gateways, and the ALB. To avoid overnight charges:

```bash
cd environments/dev
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

Budget alerts are configured at 50%, 80%, and 100% of $175/month via SNS.

---

## Architecture Reference

See the [README](../README.md) for the architecture diagram and module descriptions.

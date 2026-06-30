# Bootstrap Runbook

This guide walks through deploying the foundry-platform-demo stack from scratch. It covers every manual step required before Terraform can manage the environment autonomously.

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

```bash
export AWS_PROFILE=foundry
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# S3 bucket for state files
aws s3api create-bucket \
  --bucket "foundry-tfstate-${ACCOUNT_ID}" \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket "foundry-tfstate-${ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "foundry-tfstate-${ACCOUNT_ID}" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

aws s3api put-public-access-block \
  --bucket "foundry-tfstate-${ACCOUNT_ID}" \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name foundry-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

---

## Step 3: Clone the Repository

```bash
git clone https://github.com/lentago/foundry-platform-demo.git
cd foundry-platform-demo
```

---

## Step 4: Configure Variables

Review and update the Terraform variables for your environment:

```bash
cat environments/dev/terraform.tfvars
```

At minimum, update:
- `project` — your project name (default: `foundry`)
- `environment` — environment name (default: `dev`)
- `domain_name` — your registered domain
- Any resource sizing (RDS instance class, ElastiCache node type, etc.)

Update the backend configuration in `environments/dev/main.tf` to reference your state bucket:

```hcl
backend "s3" {
  bucket         = "foundry-tfstate-YOUR_ACCOUNT_ID"
  key            = "environments/dev/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "foundry-tfstate-lock"
  encrypt        = true
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
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/foundry-platform-demo:environment:terraform"
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
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:YOUR_ACCOUNT_ID:table/foundry-tfstate-lock"
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
  --role-name foundry-dev-github-actions-terraform \
  --assume-role-policy-document file:///tmp/terraform-role-trust.json

aws iam create-policy \
  --policy-name foundry-dev-github-actions-terraform \
  --policy-document file:///tmp/terraform-role-policy.json

# Use the policy ARN from the create-policy output
aws iam attach-role-policy \
  --role-name foundry-dev-github-actions-terraform \
  --policy-arn "arn:aws:iam::YOUR_ACCOUNT_ID:policy/foundry-dev-github-actions-terraform"
```

### 7d. Import into Terraform

```bash
cd environments/dev

terraform import \
  module.iam.aws_iam_role.github_actions_terraform \
  foundry-dev-github-actions-terraform

terraform import \
  module.iam.aws_iam_policy.github_actions_terraform \
  "arn:aws:iam::YOUR_ACCOUNT_ID:policy/foundry-dev-github-actions-terraform"

terraform import \
  module.iam.aws_iam_role_policy_attachment.github_actions_terraform \
  "foundry-dev-github-actions-terraform/arn:aws:iam::YOUR_ACCOUNT_ID:policy/foundry-dev-github-actions-terraform"
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

Push a change to the content source repo (e.g., `ice-cream-book`). The cross-repo dispatch should trigger the app deploy workflow in `foundry-platform-demo`, building and deploying the container to ECS.

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

The Terraform state backend (S3 + DynamoDB) persists across destroy/apply cycles — you never lose your state.

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

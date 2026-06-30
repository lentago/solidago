# How Workloads Relate to This Platform

This document describes how a workload (an application that runs on this platform) integrates with the infrastructure managed in this repo. The first concrete example is [`lentago/ice-cream-book`](https://github.com/lentago/ice-cream-book), which holds both the Astro/Nginx source for **icecreamtofightwith.com** and the deploy workflow that ships it.

Before the platform/workload split (issue #55), the application source lived under `app/` in this repo and a cross-repo `repository_dispatch` triggered the deploy from a content-source repo. That coupling is gone — this repo now provides infrastructure only.

## What the Platform Provides

| Resource | Module | Purpose |
|---|---|---|
| ECR repository (`foundry-dev-app`) | `modules/ecr` | Image storage |
| ECS cluster (`foundry-dev-cluster`) + service (`foundry-dev-app`) | `modules/ecs` | Where the container runs |
| ALB + listener rules | `modules/alb` | HTTPS termination, target group health checks against `/health:8080` |
| Route 53 zone + ACM certificate | `modules/dns` | DNS, TLS |
| IAM role `foundry-dev-github-actions` | `modules/iam` | OIDC-trusted role the workload assumes for ECR push / ECS update |
| KMS, Secrets Manager, RDS, ElastiCache, WAF, monitoring | `modules/*` | Available to any workload that needs them |

The platform does **not** know what the workload is. It exposes primitives; the workload decides what to put in them.

## The IAM Trust Split

There are two GitHub Actions IAM roles in `modules/iam`:

- **`foundry-dev-github-actions`** — assumed by workload repos to deploy. Trust policy: `repo:lentago/${var.app_github_repo}:*`. Currently set to `ice-cream-book`.
- **`foundry-dev-github-actions-terraform`** — assumed by this repo's `terraform` GitHub environment. Trust policy: `repo:lentago/${var.github_repo}:environment:terraform`. Plans and applies infrastructure.

Neither role can do the other's job. A compromised workload deploy can't mutate infrastructure; a compromised infrastructure pipeline can't push arbitrary container images without going through Terraform.

The variable split between `app_github_repo` and `github_repo` is what lets the workload live in a different repo than the Terraform code while still enforcing per-repo OIDC scoping.

## What a Workload Deploy Looks Like

From the workload repo's `.github/workflows/deploy.yml`:

1. Checkout the workload repo
2. Build the application (e.g., `npm ci` + `astro build`)
3. Authenticate via OIDC: GitHub JWT → STS → temporary credentials for `foundry-dev-github-actions`
4. Login to ECR
5. `docker build` + `docker push` to `foundry-dev-app`, tagged `:latest` and `:<commit-sha>`
6. `aws ecs update-service --force-new-deployment` against `foundry-dev-cluster / foundry-dev-app`
7. `aws ecs wait services-stable`

No stored AWS credentials in GitHub Secrets. The trust policy ensures only the configured workload repo can complete step 3.

## Onboarding a Second Workload

To add a second workload (e.g., `pitzilabs.dev`):

1. Decide the IAM model: share `foundry-dev-github-actions` (simpler, requires re-pointing the trust policy if only one workload is live at a time) or add a second role (more isolated, more Terraform churn).
2. If sharing: update `app_github_repo` — but this changes which repo can deploy. Multi-workload sharing isn't supported by a single trust `repo:` clause; for two concurrent workloads add a second IAM role with its own trust pattern.
3. Add a second ECR repo, ECS service, target group, and listener rule. Most existing modules accept a `project`/`environment` prefix, so a second instance with a different prefix is the pattern.
4. The new workload repo writes its own deploy workflow following the same OIDC pattern as ice-cream-book's.

This separation is the point of the platform/workload split — a second workload should require zero changes to the first one's repo, and only additive changes to this one's.

## Local Operations on Platform Resources

Even with deploys automated, you'll sometimes want to inspect ECR/ECS state from this repo:

```bash
# What images are in ECR
aws ecr describe-images \
  --repository-name foundry-dev-app \
  --query 'sort_by(imageDetails, &imagePushedAt)[-5:].[imageTags, imagePushedAt]'

# What's currently deployed
aws ecs describe-services \
  --cluster foundry-dev-cluster \
  --services foundry-dev-app \
  --query 'services[0].deployments'

# Container logs
aws logs tail /ecs/foundry-dev-app --follow
```

(Add `--profile foundry` if your default AWS profile is on a different account.)

## What This Repo Does NOT Touch in the Workload

Anything inside the workload repo — its source code, build tooling, deploy workflow, frontmatter conventions, Dockerfile — is its own concern. The platform's API surface is the IAM role ARN, the ECR repo name, the ECS cluster/service names, and the ALB target group. Beyond that, workloads are free to evolve.

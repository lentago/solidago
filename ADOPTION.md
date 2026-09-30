# Adopting Solidago

**What you're about to do:** stand up your own copy of Solidago — a complete,
three-tier AWS environment you own outright. That's a VPC (virtual private
cloud — your own isolated slice of AWS networking) with public, app, and data
subnets across two availability zones; an Application Load Balancer (ALB)
fronting containers on ECS Fargate; a PostgreSQL database (RDS) and a Redis
cache (ElastiCache); plus IAM/OIDC, secrets, DNS/TLS, monitoring, and CI/CD,
all wired together. When you're done, you have a real AWS account running a
real load-balanced web service on your own domain, deployed by GitHub Actions
with no long-lived cloud credentials stored anywhere. It's a *platform*, not a
single app — one shared ALB and ECS cluster can host several small sites side
by side.

**Why bother:** it's the same shape of infrastructure you'd reach for to put a
donor portal, a member site, or anything else your org needs live on its own
domain — built once, in the open, so you can copy it instead of starting from
a blank AWS console.

**Time:** about 45 minutes of hands-on work for a fresh account with a
registered domain, plus DNS-propagation and certificate-validation wait time
(usually under an hour, occasionally up to ~75 minutes on a cold delegation).
Nobody has run this drill start-to-finish yet, so treat that estimate as
unproven — see [Receipt](#receipt).

**What it costs:** real money, continuously — **~$130/month** running 24/7;
see [Prerequisites](#prerequisites) for the full breakdown. That's why
[Teardown](#teardown) is not optional reading.

> **Heads up.** This is not serverless and not free-tier. It runs paid,
> always-on infrastructure — NAT gateways, an ALB, RDS, ElastiCache — that
> bills by the hour whether you're using it or not. A registered domain is
> mandatory too: TLS certificates (AWS Certificate Manager, or "ACM") and DNS
> (Route 53) are load-bearing here, not add-ons.

**Status of this runbook:** never run against a fresh account —
**unexercised**. See [Receipt](#receipt).

## What you get

- A production-shaped AWS environment defined entirely in Terraform, in one
  repo you control.
- HTTPS on your own domain, terminated at the ALB with an auto-renewing ACM
  certificate.
- Container deploys via GitHub Actions using OIDC federation (OpenID Connect —
  GitHub proves its identity to AWS with a short-lived token instead of a
  stored key) — **no AWS access keys are ever stored** in GitHub.
- A selective teardown/standup pair of scripts so an idle stack costs pennies
  a day instead of ~$4.50 (see [Teardown](#teardown)).

| What | Who owns it |
|---|---|
| The repository | You (fork it) |
| The AWS account it runs in | You |
| The data (RDS, state bucket, secrets) | You |
| The domain(s) | You |
| The container images / site content | You (they live in separate workload repos you also own) |

Nothing in the running stack is owned or hosted by Lentago Labs. The reference
estate you're copying from ships coupled to *our* account, domains, and a few
external SaaS integrations (Grafana Cloud, Axiom, Anthropic) — every one of
those is listed in the [Swap list](#swap-list), and every SaaS one is
optional.

## What this is not

- **Not a managed PaaS** (platform as a service — a hosted product that runs
  the servers for you). You operate the AWS resources; Terraform only defines
  them. There's no control plane hiding the load balancer or the database
  from you.
- **Not multi-region or highly available across regions.** It's two
  availability zones in one region (`us-east-1` by default).
- **Not free, and not safe to leave running unattended.** Continuous cost is
  ~$130/month; an abandoned stack keeps billing until you tear it down.

## Prerequisites

Everything you need, in one list. No hunting through other repos.

- **Accounts:**
  - An **AWS account** with root/admin access (you'll be creating IAM roles).
  - A **GitHub account**, and an **organization or user** that will own your
    fork and the workload repo(s). CI authenticates to AWS as that org via
    OIDC, so the org name gets baked into an IAM trust policy.
  - An account at a **domain registrar** where you can edit nameserver (NS)
    records — the reference stack's domains are registered at Squarespace, but
    any registrar works.
- **A registered domain — mandatory.** ACM and Route 53 aren't optional here;
  the ALB won't serve HTTPS without a validated certificate, and validation
  happens through a Route 53 hosted zone you delegate your domain to. One
  domain is enough to start.
- **Hardware:** any machine that runs the CLIs below. Nothing special.
- **Tools:**
  - **Terraform ≥ 1.10** — state locking is S3-native (`use_lockfile`), which
    is a 1.10+ feature. Older Terraform will fail to lock.
  - **AWS CLI v2** — configured with a profile or the default credential chain.
  - **GitHub CLI (`gh`)** — for creating the environment and inspecting
    Actions runs.
  - **git**, configured with your identity.
- **Access you must already have:** AWS admin credentials on your machine
  (`aws sts get-caller-identity` must succeed); permission to edit NS records
  at your registrar; admin on your GitHub repo (to create an Environment and a
  branch-protection ruleset).
- **Optional integrations** (all skipped cleanly if you leave them blank):
  - **Grafana Cloud** — set `grafana_cloud_account_id` / `_external_id` to
    create a read-only cross-account metrics role; leave both `""` to skip the
    module entirely.
  - **Anthropic API key** — powers the optional "Ask the Wiki" Lambda; leave it
    blank and the Lambda deploys in a degraded state (returns 502) instead of
    failing.
  - **Axiom** — the reference stack ships container and ALB logs to an Axiom
    dataset. This one isn't parameterized behind an on/off flag yet; see the
    [Swap list](#swap-list).

> **Heads up — this costs real money.** **~$130/month running
> continuously**, dominated by the two NAT gateways (~$65/mo combined). Other
> line items: ALB ~$16, RDS ~$15, ElastiCache ~$12, Fargate ~$10, WAF ~$8–9,
> the rest (Route 53, CloudTrail, Config, KMS, S3) ~$5. The selective teardown
> in [`docs/RUNBOOK.md`](docs/RUNBOOK.md) drops the always-on resources when
> the stack is idle, bringing a mostly-idle stack to **roughly $40/month**.
> Budget alerts fire by email at 50/80/100% of a $100/month threshold.

**Time:** BOOTSTRAP estimates ~45 minutes for a fresh account with a registered
domain, plus DNS-propagation and ACM-validation wait time (usually under an
hour, occasionally up to ~75 minutes on a cold delegation). This drill has not
yet been independently timed — see [Receipt](#receipt).

## Intake

Every value you need to supply lives in one file:
[`environments/dev/terraform.tfvars.example`](environments/dev/terraform.tfvars.example).
Copy it to `environments/dev/terraform.tfvars` (git ignores this file, so your
answers never get committed) and fill in your answers. The third column names
the exact variable each answer becomes.

| Question | Your answer | Maps to |
|---|---|---|
| Short name for all AWS resources? (default `solidago` is fine) | | `terraform.tfvars` → `project` |
| Which deployment tier? (default `dev`) | | `terraform.tfvars` → `environment` |
| Which AWS region? (default `us-east-1`) | | `terraform.tfvars` → `aws_region` |
| An unguessable single-label subdomain for the first preview site | | `terraform.tfvars` → `lentago_preview_host` |
| A second unguessable subdomain for the second preview site | | `terraform.tfvars` → `pondview_preview_host` |
| Grafana Cloud AWS account ID (optional; blank to skip) | | `terraform.tfvars` → `grafana_cloud_account_id` |
| Grafana Cloud External ID (optional; blank to skip) | | `terraform.tfvars` → `grafana_cloud_external_id` |
| Anthropic API key for the Ask Lambda (optional; blank = degraded) | | `terraform.tfvars` → `anthropic_api_key` |

Some values are **not** Terraform variables — they're hardcoded into the
backend config, the CI workflow, and the root module. Those are handled in the
[Swap list](#swap-list) below, not here.

## Swap list

These are the opinionated values carried over from our reference estate. Find
and replace every one — an un-swapped value here is the exact failure mode
this section exists to prevent. "Mechanical" means *put your value in and
move on*. Where a value can't be cleanly parameterized, the row says so and
points at the tracking issue.

| Ours | Where it lives | Put yours here | Tracked |
|---|---|---|---|
| AWS account `365184644049` (state bucket suffix + state CMK ARN) | `environments/dev/backend.tf:3,12` | Your 12-digit account ID | mechanical |
| AWS account `365184644049` (Terraform-pipeline role ARN, ×2) | `.github/workflows/terraform.yml:98,194` | Your account ID | mechanical |
| Cross-account role ARN in a code comment (drosera's `homelab-observability` role) | `modules/iam/main.tf:516` | Delete — it documents a fleet cross-repo arrangement you don't have | mechanical |
| `solidago-*` resource naming (state bucket, CMK alias, all AWS resource names) | driven by `project` in `terraform.tfvars`; bucket/alias also in `environments/dev/backend.tf` and `scripts/bootstrap/bootstrap-backend.sh` | Your project short-name (keep it consistent across all three places) | mechanical |
| Primary domain `icecreamtofightwith.com` + wildcard `*.icecreamtofightwith.com` | `environments/dev/main.tf:161,163` (`module.dns`) | Your registered domain | mechanical |
| Apex site `lentago.dev` and its Fastmail MX/DKIM/SPF/DMARC + Google/GitHub verification tokens | `environments/dev/main.tf:319–366` (`module.lentago_domain`) | Delete the whole module block — this is our landing site, not yours | mechanical |
| Apex site `pondviewlane.com` + Google token + DMARC | `environments/dev/main.tf:455–485` (`module.pondview_domain`) | Delete the block | mechanical |
| Second apex `essexcrossingatmontserrat.com` fronting the same backend | `environments/dev/main.tf:503–530` (`module.essexcrossing_domain`) | Delete the block | mechanical |
| Extra site backends `module.site_lentago` / `module.site_pondview` / `module.ask_pondview` | `environments/dev/main.tf:250–330,374–450` | Delete the blocks (or adapt one as a template for your own second site) | mechanical |
| CORS origins `https://pondviewlane.com,https://essexcrossingatmontserrat.com` | `environments/dev/main.tf:438` (`module.ask_pondview`) | N/A once the Ask module is deleted; else your site origins | mechanical |
| Hand-allocated ALB listener-rule priorities `110/120/130/140/150` | `environments/dev/main.tf` (`listener_rule_priority` on each site/apex module) | Keep each priority unique per rule you retain; there is no auto-allocator | mechanical |
| GitHub org `lentago` + workload repos (`site-icecreamtofightwith-com`, `site-lentago-dev`, immutable `lentago@…/site-pondviewlane-com@…`) | `environments/dev/main.tf:85–133` (`module.iam` inputs) | Your org and your workload repo name(s) — this is the OIDC deploy trust | mechanical |
| Cross-repo tfstate role `dotgithub-github-actions-terraform` trusting `lentago/.github` | `modules/iam/main.tf:~500–560` + `dotgithub_repo` input | Delete if you have no shared-workflows repo needing state access | mechanical |
| Terraform-pipeline OIDC trust `repo:<org>/solidago:environment:terraform` | created by hand in the drill; see BOOTSTRAP Step 7 | Your org/repo | mechanical |
| Axiom datasets `cjp-solidago-ecs` / `cjp-solidago-alb` + the FireLens sidecar and ALB-log shipper wiring | `environments/dev/main.tf:180–224,270,379` and `module.secrets` | Requires an Axiom account, or delete the `axiom_*` inputs + `module.alb_log_shipper` by hand | **structural** — there is no skip flag yet, unlike Grafana Cloud. Tracked in [#188](https://github.com/lentago/solidago/issues/188) |
| Monthly budget threshold `$100` | `environments/dev/main.tf` (`module.budgets`) | Your budget | mechanical |

**On plan cleanliness:** our own repo's CI plans are *not* clean — three ECS
task definitions and one SNS subscription always show as pending changes
because live deploys run ahead of Terraform. That drift is tracked in
[issue #184](https://github.com/lentago/solidago/issues/184). Your **first**
plan against a fresh account is all creates and free of that noise; the same
drift shows up only after you deploy a container image and re-plan. When a
drill step below says "check the plan," read it with #184 in mind — those
three task-definition replacements are known and not your error.

## The drill

Numbered, one action per step, **local-first**: everything you can verify
offline comes before anything that touches AWS or costs money. Placeholders
look like `<LOUD>`. If a check doesn't go green, stop there — the next step
assumes the one before it worked.

| # | Step | Check it's green | ✅ |
|---|---|---|---|
| 1 | Install the tools. `terraform version`, `aws --version`, `gh --version`, `git --version`. | Terraform reports **≥ 1.10**; AWS CLI reports **v2**; all four print a version. | |
| 2 | Fork/clone the repo and `cd solidago`. | `git remote -v` shows your fork. | |
| 3 | `cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars` and fill in the [Intake](#intake) values. | `grep -R "change-me" environments/dev/terraform.tfvars` returns **nothing**. | |
| 4 | Work the [Swap list](#swap-list): replace the account ID, domain, and GitHub org; delete the extra site/apex/Axiom blocks you don't want. | `grep -R "365184644049\|icecreamtofightwith\.com\|cjp-solidago" environments .github` returns only your values (or nothing). | |
| 5 | Validate locally, no backend, no AWS calls: `cd environments/dev && terraform init -backend=false && terraform validate`. | Prints **"Success! The configuration is valid."** | |
| 6 | Bootstrap the state backend (first AWS touch; a bucket + a KMS key, pennies): `./scripts/bootstrap/bootstrap-backend.sh`, then set your account ID in `environments/dev/backend.tf`. | `aws s3 ls s3://<YOUR_PROJECT>-tfstate-<YOUR_ACCOUNT_ID>` succeeds. | |
| 7 | Real init + plan: `terraform init` then `terraform plan`. | Plan completes and shows **only creates** (a fresh account has no drift — see #184). | |
| 8 | First apply from your machine (creates the OIDC provider + app deploy role; ~10–15 min): `terraform apply`. | Apply succeeds; `terraform output` shows `route53_name_servers` and `github_actions_role_arn`. | |
| 9 | Delegate DNS: set your registrar's NS records to the `route53_name_servers` output. | `dig NS <YOUR_DOMAIN>` returns the four Route 53 nameservers. | |
| 10 | **⚠️ Identity-provider bootstrap — the trip hazard. See the warning below.** Create the Terraform-pipeline IAM role by hand and `terraform import` it (three imports), per [BOOTSTRAP Step 7](docs/BOOTSTRAP.md#step-7-create-the-terraform-pipeline-iam-role). | `terraform plan` reports **No changes** for the imported role/policy/attachment. | |
| 11 | Create the GitHub `terraform` Environment and a `main` branch-protection ruleset requiring the Terraform Plan check ([BOOTSTRAP Steps 8–9](docs/BOOTSTRAP.md#step-8-create-the-github-environment)). | Repo → Settings shows the `terraform` environment and the ruleset. | |
| 12 | Verify the pipelines: open a trivial PR (plan runs), merge it (apply runs) ([BOOTSTRAP Step 10](docs/BOOTSTRAP.md#step-10-verify-the-pipelines)). | The PR's **Terraform Plan** check is green; the post-merge **Apply** completes. | |

**If a check doesn't go green,** stop at that step and see
[Troubleshooting](#troubleshooting).

> **Heads up — this is where people get stuck: Step 10.** Unlike the other
> steps, the Terraform-pipeline role in Step 10 is **not** created by
> `terraform apply`. It's a chicken-and-egg bootstrap: the role that lets CI
> run Terraform can't itself be created by that CI. So you create the IAM
> role and policy **by hand with the AWS CLI**, then run **three
> `terraform import` commands** to adopt them into state so Terraform manages
> them from then on. The exact commands and JSON are in
> [BOOTSTRAP Step 7](docs/BOOTSTRAP.md#step-7-create-the-terraform-pipeline-iam-role) —
> follow them verbatim, substituting your account ID and org. If the import
> addresses or the OIDC `sub` claim (`repo:<org>/solidago:environment:terraform`)
> don't match exactly, `terraform plan` will show the role being **destroyed
> and recreated** instead of "No changes" — that's the tell that the import
> didn't take. Fix the trust policy or re-run the import before proceeding.

## Verify it works

Here's how you know it worked: a page served over HTTPS from your own domain,
end to end.

- `curl -I https://<YOUR_DOMAIN>` returns **HTTP/2 200** with a valid,
  non-self-signed certificate (your browser shows the padlock, no warning).
- The request is actually being load-balanced: the response comes from an ECS
  Fargate task, not a placeholder — the ALB target group shows **healthy**
  targets in the AWS console (or via `aws elbv2 describe-target-health`).
- If you kept the monitoring module, a metric shows up: the CloudWatch
  dashboard for your ALB shows request count climbing after your `curl`s.

A green CI run is *not* the proof — the page actually loading is.

## Receipt

<!-- Blank on purpose: this drill has not been run against a fresh account.
     Do not fill in an estimate. When someone runs it end to end, they record
     the real numbers here and flip the status line at the top to "exercised". -->

| Field | Value |
|---|---|
| Date | |
| Operator | |
| Version tested | |
| Deploy target | |
| Total elapsed | |
| Slowest step | |
| All checks green | |
| Notes | |

**Status: unexercised.** No one has yet run this drill start-to-finish against
a fresh AWS account. An empty receipt is information — it means the numbers
above are unproven, not that they are zero.

## Teardown

Removing this stack is a first-class operation here, documented in full at
[`docs/RUNBOOK.md`](docs/RUNBOOK.md). Two modes:

- **Selective teardown** (day-to-day): `scripts/teardown.sh` destroys only the
  expensive always-on resources (NAT gateways, ALB, Fargate tasks, ElastiCache;
  RDS is *stopped*, not destroyed) and keeps the durable foundation, so
  `scripts/standup.sh` brings it back in minutes. This is how you park an idle
  stack at ~$40/month equivalent instead of ~$130.
- **Full teardown**: `terraform destroy` from `environments/dev` removes
  everything Terraform manages. The state bucket and its dedicated KMS key are
  bootstrapped *outside* Terraform and are deliberately **not** destroyed —
  they cost pennies and hold your state.

**Confirm the billing actually stopped.** This is the section that should
earn your trust in the rest of the document, so verify it explicitly — don't
take our word for it:

- `aws ec2 describe-nat-gateways --filter Name=state,Values=available` returns
  **empty** — NAT gateways are the largest line item and bill until deleted.
- `aws elbv2 describe-load-balancers` returns **no** ALB (full teardown) or the
  expected count.
- `aws rds describe-db-instances --query 'DBInstances[].DBInstanceStatus'`
  shows **`stopped`** (selective) or the instance is gone (full). A *stopped*
  RDS instance still bills for storage and auto-restarts after 7 days — take a
  snapshot and use `RDS_MODE=destroy` to stop all RDS charges.
- In **Cost Explorer** (or `aws ce get-cost-and-usage` for a daily
  granularity), the daily cost drops to near-zero within a day or two. This is
  the definitive check — a resource you forgot shows up here as a line that
  never goes to zero.
- After a **full** teardown the only resources left should be the state S3
  bucket and the `alias/<project>-tfstate` KMS key. Anything else still running
  is a leak — chase it in Cost Explorer.

## You are operationally ready when

- [ ] `https://<YOUR_DOMAIN>` serves your app with a valid certificate
- [ ] Deploys run through GitHub Actions via OIDC — no AWS keys in the repo
- [ ] The RDS instance is reachable from the app and you have **taken and
      restored a snapshot** at least once
- [ ] Budget/alarm emails reach a human inbox you actually read (confirm the
      SNS subscription — see [issue #184](https://github.com/lentago/solidago/issues/184))
- [ ] `terraform.tfvars` holds *your* secrets, and no `change-me` placeholder or
      example value remains
- [ ] You have run `scripts/teardown.sh` and `scripts/standup.sh` at least once
      and confirmed billing dropped in Cost Explorer
- [ ] Someone other than you can follow this document from a clean clone

## Troubleshooting

Real failures seen bringing this stack up, symptom first.

**Symptom:** `terraform apply` hangs for a long time on
`aws_acm_certificate_validation`.
**Cause:** DNS is not delegated yet, so ACM cannot see the validation records.
**Fix:** Complete drill Step 9 (set the NS records at your registrar) and wait
for propagation; validation can take up to ~75 minutes on a cold delegation.

**Symptom:** ECS service creation fails with *"target group does not have an
associated load balancer."*
**Cause:** A cold-start race — the HTTPS listener isn't up yet because ACM is
still validating (issue #50). The root module already declares the ordering
dependency; a re-apply after the listener exists succeeds.
**Fix:** Re-run `terraform apply` once the certificate is `ISSUED`.

**Symptom:** State operations fail with `AccessDenied` on a KMS key even though
S3 permissions look right.
**Cause:** The state bucket is SSE-KMS encrypted with the dedicated
`alias/<project>-tfstate` key, whose policy delegates authorization to IAM. A
role reading state needs an explicit `kms:Decrypt`/`GenerateDataKey`/`DescribeKey`
grant on that key ARN.
**Fix:** Confirm the role has the KMS grant (the CI roles get it via
`modules/iam`); a human running locally needs admin or the same grant.

**Symptom:** `terraform plan` in Step 10 shows the Terraform-pipeline role being
**destroyed and recreated** instead of "No changes."
**Cause:** The `terraform import` didn't match — usually the OIDC `sub`
condition or an import address is off.
**Fix:** Compare your role's trust policy to BOOTSTRAP Step 7 exactly, correct
it, and re-import.

**Symptom:** Every CI plan shows three ECS task definitions "must be replaced"
and an SNS subscription being created.
**Cause:** Not your error — live deploys run ahead of Terraform. Tracked in
[issue #184](https://github.com/lentago/solidago/issues/184).
**Fix:** Expected on the reference estate; a fresh account only sees it after
its first container deploy. Confirm the SNS email subscription once so alerts
deliver.

## Getting help

Open an issue on this repository. Include: what step you were on, the exact
command, the full output, and your platform (Terraform/AWS CLI versions). If a
step here was wrong, unclear, or missing a prerequisite, that's the most
valuable issue you can file — this runbook is **unexercised**, and you may be
the first person to run it end to end and find things worth fixing.

---

**Runbook owner:** @cpitzi · **Last verified:** never (unexercised — see
[Receipt](#receipt))

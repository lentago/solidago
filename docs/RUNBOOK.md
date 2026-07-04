# Teardown / Standup Runbook

Selective, cost-saving teardown of the foundry-dev platform and how to bring it
back. The goal: destroy the expensive always-on resources when the lab is idle,
**without** destroying the durable foundation, so a rebuild takes minutes instead
of the 15–20 minute (and occasionally ~75 minute) resurrection pain of a full
`terraform destroy` / `apply`.

For a from-scratch deployment (fresh AWS account, no state), use
[BOOTSTRAP.md](BOOTSTRAP.md) instead. This runbook assumes the platform has
already been bootstrapped and stood up at least once.

> **Scripts:** [`scripts/teardown.sh`](../scripts/teardown.sh) and
> [`scripts/standup.sh`](../scripts/standup.sh). This runbook is the narrative;
> the scripts are the automation. They encode every rule below.

---

## TL;DR

```bash
cd <repo root>
export AWS_PROFILE=...                       # or rely on the default cred chain
export TF_VAR_pitzilabs_preview_host=...     # mirror the CI Actions variables
export TF_VAR_lentago_preview_host=...

# End of session — stop paying for idle resources:
scripts/teardown.sh

# Next session — bring it all back:
scripts/standup.sh
```

Savings: roughly **$4.50/day** in idle cost (NAT gateways are the largest slice),
with the durable foundation left in place so ACM, DNS, KMS, IAM, and ECR images
all survive.

---

## What is EPHEMERAL vs KEEP

The classification is the whole point. Everything expensive-and-easy-to-recreate
is torn down; everything cheap-but-painful-to-recreate is kept.

### EPHEMERAL — destroyed by `teardown.sh`

| Resource | Terraform target | Why |
|----------|------------------|-----|
| NAT Gateways + EIPs | `module.vpc.aws_nat_gateway.main`, `module.vpc.aws_eip.nat` | ~$2.15/day — the biggest idle cost |
| Application Load Balancer | `module.alb` | ~$0.65/day |
| Primary app ECS service/tasks | `module.ecs.aws_ecs_service.app` | ~$0.80/day of Fargate |
| Preview-site ECS services/tasks | `module.site_pitzilabs.aws_ecs_service.this`, `module.site_lentago.aws_ecs_service.this` | Fargate tasks |
| ElastiCache replication group | `module.elasticache.aws_elasticache_replication_group.this` | ~$0.40/day |
| RDS instance | **stopped** by default; `module.rds.aws_db_instance.main` only with `RDS_MODE=destroy` | ~$0.93/day |

**Cascade dependents** are pulled in automatically by `terraform destroy -target`
because they depend on the resources above — and are recreated by standup's full
apply:

- CloudWatch dashboard (`module.dashboard`) — references the ALB/NAT/RDS/cache
- ALB / ECS / RDS / ElastiCache alarms (`module.monitoring`)
- WAF ↔ ALB association (`module.waf.aws_wafv2_web_acl_association.alb`) — the Web
  ACL itself is kept
- Route 53 ALB alias record and the preview-site listener rules / DNS records

This is expected. After teardown, `terraform plan` will show a long list of
resources *to add* — that is the cascade set waiting to be rebuilt by standup.

### KEEP — never touched by these scripts

| Resource | Where | Why it is kept |
|----------|-------|----------------|
| S3 state bucket + its KMS CMK | bootstrap (`alias/foundry-tfstate`) | Holds the state itself; **must never be destroyed** — see below |
| IAM roles / OIDC provider | `module.iam` | Free; recreating churns trust relationships |
| ECR repositories + images | `module.ecr`, plus the ECR repos inside `module.site_*` | **Deleting them empties the registries → all sites 503** until re-pushed |
| Route 53 hosted zone + ACM cert | `module.dns` (zone + certificate) | Recreating changes nameservers → forces registrar re-delegation + ~75 min ACM hang |
| Terraform-managed KMS key | `module.kms` (`alias/foundry-dev-main`) | 30-day recovery window; also entangled with the RDS/secret re-key trap |
| Secrets Manager secrets | `module.secrets` | 7-day recovery window |
| Security groups, VPC core, CloudWatch log groups | `module.security_groups`, `module.vpc` (subnets/IGW/public route table), log groups in `module.ecs` etc. | Free and/or hold history |

> **The state bucket and its bootstrap KMS key (`alias/foundry-tfstate`) must
> NEVER be destroyed.** They live outside Terraform on purpose (chicken-and-egg)
> and are not managed by any module, so no `terraform destroy` can reach them —
> neither script references them. If either is lost, you lose access to your own
> state. See [BOOTSTRAP.md](BOOTSTRAP.md) for why the state key is deliberately
> separate from the Terraform-managed `alias/foundry-dev-main` key.

---

## Why the scripts target resources, not whole modules

Two `KEEP` rules force sub-module granularity:

1. **The `site` modules own ECR repositories.** `module.site_pitzilabs` and
   `module.site_lentago` each contain an `aws_ecr_repository`. Destroying the
   whole module would delete the repo and its images (violating constraint b).
   So teardown targets only each site's `aws_ecs_service.this`.
2. **`module.ecs` owns the app CloudWatch log group.** Targeting the whole
   module would drop the log group. Teardown targets only
   `module.ecs.aws_ecs_service.app`, keeping the cluster, task definition, and
   log group.

A Terraform toggle variable per module would be an alternative, but it would mean
editing every module. Targeted destroy keeps all the logic in the scripts and
touches no Terraform code.

---

## Teardown procedure

### Prerequisites

- `terraform` and `aws` CLI on `PATH`
- AWS credentials (default chain or `AWS_PROFILE`) for the account
- `TF_VAR_pitzilabs_preview_host` and `TF_VAR_lentago_preview_host` exported —
  Terraform requires all variables even for a targeted destroy. These mirror the
  repo Actions variables `PITZILABS_PREVIEW_HOST` / `LENTAGO_PREVIEW_HOST`.

### Run

```bash
scripts/teardown.sh          # interactive confirmation
scripts/teardown.sh -y       # non-interactive (or AUTO_APPROVE=1)
```

The script:

1. Preflights (tools, required vars, AWS auth, `RDS_MODE` value).
2. Prints exactly what will be destroyed and asks for confirmation.
3. **Stops** the RDS instance (default) — see the RDS section below.
4. Runs one `terraform destroy` with all ephemeral `-target`s. Terraform orders
   the graph and pulls in the cascade dependents.

### RDS: stop vs destroy

| Mode | Command | Data | Cost | Notes |
|------|---------|------|------|-------|
| `stop` (default) | `RDS_MODE=stop scripts/teardown.sh` | **Preserved** | Saves instance-hours; storage still billed | AWS auto-starts a stopped instance after **7 days** |
| `destroy` | `RDS_MODE=destroy scripts/teardown.sh` | **LOST** (`skip_final_snapshot = true`) | Saves storage too | Take a manual snapshot first if you need the data |

**Default is `stop`** for three reasons: it preserves the database, saves the bulk
of the cost (instance-hours), and — critically — it **sidesteps the KMS-secret
re-key trap** from issue #20. Stopping never deletes the RDS-managed
`db-credentials` secret, so it can never come back bound to a delete-scheduled
KMS key. In a *selective* teardown the Terraform KMS key is kept and never
delete-scheduled, so even `RDS_MODE=destroy` is safe from that trap here — the
trap is specifically a **full-destroy** hazard (see below).

`aws rds stop-db-instance` works on the Multi-AZ instance this stack provisions.

To reclaim storage cost for an idle longer than 7 days, take a snapshot and use
`RDS_MODE=destroy`; standup will recreate an empty instance (restore from the
snapshot manually if needed).

---

## Standup procedure

### Run

```bash
scripts/standup.sh           # interactive apply
scripts/standup.sh -y        # -auto-approve (or AUTO_APPROVE=1)
scripts/standup.sh --wait    # also block until RDS is 'available' first
```

The script:

1. Preflights (tools, required vars, AWS auth) and `terraform init` if needed.
2. **Constraint (a) guard:** confirms `module.dns.aws_route53_zone.main` is still
   in state. If it is missing, it aborts with the two-phase instructions below —
   because a blind full apply would create a *new* zone with *new* nameservers
   and ACM validation would hang until re-delegation.
3. **Starts** the RDS instance if it is stopped (`--wait` to block on it).
4. Runs a **full** `terraform apply` (no `-target`) to reconcile every ephemeral
   resource and cascade dependent back to config, in dependency order.

A full apply is used deliberately: the durable foundation matches config already
(no-op), and a no-target apply is the only way to guarantee the cascade
dependents (dashboard, alarms, WAF association, alias/listener records) all come
back — a targeted apply would miss them.

### After standup

- **ECR was kept**, so images survive and the sites serve immediately.
- If a site returns **503**, its ECR repo is empty (constraint b): re-run that
  workload repo's **Build & Deploy** workflow (e.g.
  [site-icecreamtofightwith-com](https://github.com/lentago/site-icecreamtofightwith-com)) to re-push the
  image. Terraform recreates the ECR repo and ECS service but never the image.

---

## Known constraints (encoded in the scripts)

These are the sharp edges surfaced from prior teardown→rebuild cycles. Each is
enforced or documented by the scripts.

### (a) Two-phase apply when the hosted zone does not exist

The Route 53 zone must exist **and be delegated at the registrar** before other
applies, or **ACM certificate validation hangs (~75 min)** waiting on DNS
records the world can't resolve.

- In a *selective* standup the zone + cert are **kept**, so a single apply is
  safe. `standup.sh` verifies the zone is still in state and refuses to proceed
  if it is not.
- If the zone is gone (full teardown, or someone deleted it), do a **two-phase
  standup**:

  ```bash
  # Phase 1 — create just the zone
  terraform -chdir=environments/dev apply -target=module.dns.aws_route53_zone.main

  # Phase 2 — re-delegate at the registrar
  terraform -chdir=environments/dev output route53_name_servers
  #   → set these NS records at your domain registrar and wait for propagation

  # Phase 3 — bring up the rest
  scripts/standup.sh
  ```

### (b) Teardown must NOT delete ECR repositories

If the ECR repos were deleted, a rebuild recreates them **empty**, and **all
three sites return 503** until each workload repo's Build & Deploy re-pushes its
image. Teardown therefore targets only ECS *services*, never the `module.ecr` or
`module.site_*` modules that own the repos. Images persist across a normal
teardown/standup cycle.

### (c) KMS-secret re-key trap (full destroy only) — issue #20

On a **full** `terraform destroy`, the Terraform-managed KMS key is scheduled for
deletion. A subsequently restored `db-credentials` secret can come back on that
old, delete-scheduled key and **stall convergence** until the secret is manually
force-deleted. Selective teardown avoids this entirely by keeping the KMS key
(never delete-scheduled) and, by default, only *stopping* RDS. If you ever hit
this after a full destroy, force-delete the stale secret:

```bash
aws secretsmanager delete-secret --secret-id <db-credentials arn> \
  --force-delete-without-recovery
```

---

## Cost reference

With everything running 24/7 the environment is ~$130–140/month; the largest
line items are NAT Gateways (~$65), ALB (~$16), RDS (~$15), and ElastiCache
(~$12). A nightly selective teardown removes essentially all of the NAT, ALB, and
Fargate cost and (with `RDS_MODE=destroy`) the RDS/cache cost too — roughly
$4.50/day of idle spend — while the kept foundation costs only pennies a day.

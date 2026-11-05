# ADR-0005: Selective nightly teardown as the cost model

**Status:** Accepted (2026-07-01; reconstructed 2026-08-13). The retrospective's verdict on Fargate Spot is superseded for the site services by [ADR-0010](0010-dev-runs-cost-first-where-it-keeps-the-product-claims.md) (2026-11-05).

## Context

The environment runs on personal money — roughly $130–140/month with everything
running 24/7, dominated by NAT Gateways (~$65), ALB (~$16), RDS (~$15), and
ElastiCache (~$12). The naive cost control is `terraform destroy` at night and
`terraform apply` in the morning. But a from-scratch rebuild pays the
~75-minute ACM certificate revalidation each time, and re-creating the Route 53
zone would change the authoritative nameservers. That is too slow and too
fragile to run every day. Issue #14 asked for a cost model that could.

## Decision

A **selective** teardown, not a full destroy/apply. Scripts drop only the
expensive always-on resources and keep the durable foundation (PR #76,
Closes #14):

- **Torn down nightly:** NAT Gateways, ALB, Fargate tasks, RDS, ElastiCache.
- **Kept:** the state backend, IAM/OIDC, ECR images, Route 53 zone + ACM cert,
  KMS, and secrets.

Keeping the ACM cert and Route 53 zone is what avoids the ~75-minute
revalidation and keeps nameservers stable, so a morning rebuild takes minutes.
The scripts target specific *resources*, not whole modules, because several
modules co-own resources that must survive (e.g. an ECR repo or a CloudWatch log
group) — deleting the module would take the wrong things with it. This makes the
cost model itself part of the codebase: budgets and teardown are expressed as
code (`scripts/teardown.sh`, `scripts/standup.sh`, `docs/RUNBOOK.md`).

## Alternatives

**Recorded at the time**

- *Full `terraform destroy` / `terraform apply`.* The incumbent, superseded by
  PR #76. **Worse** for a daily cadence: it pays ~75 minutes of ACM
  revalidation on every rebuild and puts the `prevent_destroy` Route 53 zone /
  nameserver stability at risk. State persistence in S3 makes it *correct*, just
  too slow and too blunt to run nightly.
- *Leave everything running 24/7.* Rejected on cost — ~$130–140/month for a
  learning lab that is idle most of the night.

**Retrospective — not considered at the time**

- *fck-nat (a NAT instance) instead of managed NAT Gateways.* **Cheaper** — it
  would cut the single largest line item (~$65/mo of NAT) to a few dollars of
  EC2, and could stay up instead of being torn down. But **less
  production-faithful**: the repo's stated intent is to model how a production
  environment should be built, and managed NAT Gateways are the production
  pattern. It trades the demonstration value for a lower bill — a lateral move at
  best for this project's goals, even though it would be an easy win for a
  purely cost-driven lab.
- *Fargate Spot for the ECS tasks.* **Cheaper** for the compute tier and simpler
  than tearing tasks down and back up. But Spot interruptions are the opposite of
  the always-available production posture the platform is demonstrating, and the
  savings are small next to NAT. **Lateral** — a real option, but off-message for
  a repo whose point is production faithfulness, not minimum cost.

## Consequences

- A morning standup takes minutes rather than the ~75-minute from-scratch
  rebuild, because the ACM cert and Route 53 zone never go away.
- Overnight, the platform is intentionally down. By design these overnight gaps
  are treated as the expected daily disaster-recovery drill rather than an
  incident — the rebuild path *is* the DR path, exercised every day. (Downstream
  observability lives in `lentago/drosera`; see
  [ADR-0001](0001-grafana-is-visualization-not-alerting.md).)
- Teardown/standup must target resources precisely, because deleting a whole
  module would remove co-owned resources meant to survive (ECR images, log
  groups). This precision is a maintenance cost the scripts carry.

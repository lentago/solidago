# ADR-0010: Dev runs cost-first where it keeps the product claims

**Status:** Accepted (2026-11-05; documented 2026-11-05). Partly supersedes the
retrospective in [ADR-0005](0005-selective-teardown-as-the-cost-model.md).

## Context

The environment runs 24/7 on personal money. From August to October 2026 it
cost $212–225 a month (Cost Explorer), against an earlier estimate of
$130–140. Several of the platform's choices had been made for production
faithfulness: a NAT gateway in each AZ, Multi-AZ RDS, two app tasks spread
across AZs, on-demand Fargate everywhere, and four WAF rules. ADR-0005's
retrospective set two cheaper options aside on those grounds: fck-nat
("less production-faithful") and Fargate Spot ("off-message for a repo whose
point is production faithfulness").

On 2026-11-05 a spending review across the Lentago estate put a trimming plan
to Chris in tiers. He approved Tier 2, "AWS quick wins, no product change"
([#271](https://github.com/lentago/solidago/issues/271)), and option B of the
Tier 4 judgment, "tweaks that keep every product claim"
([#277](https://github.com/lentago/solidago/issues/277)).

## Decision

For the dev environment, cost wins over production faithfulness wherever the
change keeps what the platform claims to demonstrate. The platform still
demonstrates multi-AZ networking, private tiers, a managed database with
backups and point-in-time recovery, autoscaling, a WAF and alerting:

| Change | Was | Now | Issue |
|--------|-----|-----|-------|
| NAT | one gateway per AZ | one gateway, in us-east-1a, for both AZs (`single_nat_gateway`) | #271 |
| Container Insights | enabled | disabled; the free `AWS/ECS` service metrics remain | #271 |
| RDS | Multi-AZ | Single-AZ, modifications applied immediately | #271 |
| Monthly budget | $100, below the run rate | $175, above the expected run rate of about $150 | #271 |
| App service | floor of two tasks | floor of one, scaling to six | #277 |
| Site services (lentago.dev, pondviewlane.com) | on-demand Fargate | Fargate Spot | #277 |
| WAF | four rules | Common Rule Set plus the per-IP rate limit | #277 |
| App service CPU | x86_64 | ARM64 (Graviton), once the image builds multi-arch | #277 |

The modules keep the production-faithful defaults: one NAT gateway per AZ,
Multi-AZ RDS, an autoscaling floor of two, and on-demand Fargate. Dev opts out
in `environments/dev/main.tf`, so an environment built from these modules for
real use gets the faithful shape unless it chooses otherwise.

Not taken, still open: fck-nat (about $23 a month more), the ElastiCache node,
and site images on ARM (Spot does not run ARM64). Declined: moving the static
sites to S3 and CloudFront (option D of the Tier 4 judgment).

## Consequences

- Expected run rate falls from about $220 to about $125 a month: about $73
  from #271 and about $26 from #277.
- **Availability at rest is lower.** An outage of us-east-1a takes out private
  egress for both AZs. An RDS instance failure is recovered by restore, not by
  failover. A failure of the one app task, or an interruption of a site's one
  Spot task, is a gap of a few minutes until the replacement passes its
  health check. drosera's SLO fast-burn tier pages on a gap that long;
  [lentago/drosera#320](https://github.com/lentago/drosera/issues/320) decides
  how drosera treats it.
- **Less filtering at the edge.** Log4j, Java-deserialization and
  known-bad-IP traffic is no longer blocked by a managed rule. It reaches
  nginx serving static files. WAF logging still records every request.
- ADR-0005's verdict on Fargate Spot ("off-message") no longer holds for the
  site services. Its verdict on fck-nat stands until someone takes that
  option up.

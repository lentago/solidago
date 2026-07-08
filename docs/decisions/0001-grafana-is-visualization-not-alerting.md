# ADR-0001: Grafana is visualization, not alerting

**Status:** Accepted (2026-07-04)

## Context

Phase 1 of the Lentago observability fabric connects Solidago platform
metrics to the `lentago.grafana.net` stack (managed from `lentago/drosera`)
via a query-on-demand CloudWatch datasource assuming the read-only
`solidago-dev-grafana-cloudwatch` role. With platform metrics now rendering
in Grafana Cloud, the question arises whether alerting should move there
too.

## Decision

CloudWatch alarms → SNS remain the **sole alerting plane**. Grafana Cloud
is a visualization/exploration plane fed by a query-on-demand CloudWatch
datasource. No Grafana-managed alert rules are created against Solidago
metrics.

## Consequences

- **Blast radius:** alerting survives failures of the Lentago lab LXC, the
  Grafana Cloud free tier, and the datasource's IAM trust. The failure
  domain of "we can't see" never overlaps the failure domain of "we can't
  be paged."
- Solidago dashboards live in `lentago/drosera` (the drosera side of the
  cross-repo contract; see its README § "Solidago (AWS) contract").
- Any future Grafana-managed alerting requires revisiting this ADR.

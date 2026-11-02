# Architecture Decision Records

These records were **reconstructed on 2026-08-13** by a fleet-wide ADR sweep that
recovered Solidago's architectural decisions from commit history, issues and PRs,
`CLAUDE.md`, `docs/reference-notes.md`, and session archives. They were not written
at the time each decision was made. The **Status** date on each record is the
*original* decision date (verified against the evidence cited inside); the
"reconstructed 2026-08-13" note records when the ADR itself was written.

Each record's **Alternatives** section distinguishes options that were actually
weighed at the time (drawn from the cited evidence) from options marked
*"retrospective — not considered at the time"*, which are assessed here with
hindsight and were **not** part of the original decision.

ADRs added after the 2026-08-13 sweep (e.g. [0008](0008-dev-tier-rds-deletion-protection-off-no-final-snapshot.md))
follow the same "Status" convention — original decision date, then when the
record was written — but were filed individually, not recovered as part of
that sweep.

| ADR | Title | Original date |
|-----|-------|---------------|
| [0001](0001-grafana-is-visualization-not-alerting.md) | Grafana is visualization, not alerting | 2026-07-04 |
| [0002](0002-github-oidc-only-dual-role-trust-split.md) | GitHub OIDC only, with a dual-role trust split | 2026-02-28 |
| [0003](0003-shared-alb-and-ecs-as-a-multi-site-platform.md) | Shared ALB + shared ECS cluster as a multi-site platform | 2026-06-16 |
| [0004](0004-state-backend-dedicated-cmk-and-s3-native-locking.md) | State backend: dedicated bootstrap-managed CMK + S3-native locking | 2026-07-01 |
| [0005](0005-selective-teardown-as-the-cost-model.md) | Selective nightly teardown as the cost model | 2026-07-01 |
| [0006](0006-service-level-iam-wildcards-oidc-sub-is-the-boundary.md) | Service-level IAM wildcards; OIDC sub scoping is the real boundary | 2026-02-28 |
| [0007](0007-full-codename-rename-including-live-aws-and-tfstate.md) | Full codename rename, including live AWS resources and the tfstate backend | 2026-07-08 |
| [0008](0008-dev-tier-rds-deletion-protection-off-no-final-snapshot.md) | Dev-tier RDS runs with deletion protection off and no final snapshot | 2026-03-19 |
| [0009](0009-log-groups-stay-on-the-default-key-except-visitor-text.md) | CloudWatch log groups stay on the default key, except the one that holds visitor text | 2026-11-02 |

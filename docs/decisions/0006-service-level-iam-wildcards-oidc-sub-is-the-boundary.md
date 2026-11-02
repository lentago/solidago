# ADR-0006: Service-level IAM wildcards; OIDC sub scoping is the real boundary

**Status:** Accepted (2026-02-28; reconstructed 2026-08-13)

## Context

The Terraform CI role has to manage every service the platform touches — EC2,
ECS, RDS, IAM, KMS, Lambda, and more — and that surface grows every time a module
is added. Writing per-action IAM policies for a role that provisions the whole
account means the policy needs an edit for essentially every new module, and a
*missing* action silently breaks the pipeline. The question is where the real
security boundary sits: in per-action IAM restrictions on the role, or in *who
can assume the role at all*.

## Decision

The Terraform CI role uses **service-level wildcards** (`ec2:*`, `ecs:*`, and so
on), and the real boundary is the **OIDC subject claim** that scopes who may
assume it — the role's trust policy is pinned to
`repo:lentago/solidago:environment:terraform`, so only the `terraform.yml`
workflow running in that GitHub environment can assume it (README § "Design
Decisions" / "Service-Level IAM Wildcards on the Terraform Role"). Service-level
wildcards keep the policy maintainable as modules evolve; the OIDC trust ensures
only the intended workflow ever gets those permissions.

The cost of the *alternative* — trying to enumerate exact permissions — was
demonstrated concretely: the deploy role lacked `lambda:*`, which blocked the
ALB-log shipper deploy **and every merge to `main`** until it was granted (issue
#110; fixed in PR #112, which granted `lambda:*` and made the package build
plan-safe). A single missing service wildcard took down the whole merge path —
evidence that, for a sole-operator account, the maintenance fragility of
fine-grained action lists is a real operational hazard, while the assume-role
boundary is what actually contains risk.

## Alternatives

**Recorded at the time**

- *Fine-grained per-action IAM policies on the CI roles.* The conventional
  least-privilege approach. Not chosen for the CI roles because the role
  provisions the entire account and the action list would need constant editing —
  and issue #110 / PR #112 showed the failure mode when it drifts out of date: a
  missing `lambda:*` blocked all merges to `main`. **Worse** here: high
  maintenance, brittle, and it does not tighten the boundary that matters (who can
  assume the role) — it only makes an already-trusted pipeline more likely to
  break.

**Retrospective — not considered at the time**

- *IAM permission boundaries or SCPs* capping what the CI role can do even with
  wildcard action grants. This is **better defense-in-depth**: a boundary/SCP
  would contain the blast radius if the OIDC trust were ever misconfigured or the
  workflow subverted, without reintroducing per-action churn (the boundary is a
  coarse ceiling, not a per-module allow-list). The reason it is retrospective is
  **weight**: SCPs require AWS Organizations, and a permission boundary is another
  policy to author and maintain for a single-operator, single-account lab where
  the OIDC subject is already the effective gate. Worth it if this grew beyond one
  account or one operator; overhead without payoff at today's scale.

## Consequences

- The Terraform role's policy rarely needs editing when a module is added, so new
  modules don't routinely stall on a missing IAM action — with the sharp
  exception of a genuinely new *service* (as `lambda:*` was in #110), which still
  requires adding that service's wildcard.
- The security story hinges entirely on the OIDC trust policy being correct: the
  `environment:terraform` sub-claim scoping is doing the real work, so any change
  to that trust is a change to the platform's core boundary and must be reviewed
  as such.
- There is no second layer (boundary/SCP) beneath the OIDC gate. In this account
  that is an accepted trade; it would be the first thing to revisit if the account
  ever stopped being single-operator.

## Amendment (2026-11-01, #225, #156)

The wildcards stand; the boundary they rely on was weaker than this record
said. The `terraform` environment had no deployment branch policy, so any job
on any branch that declared `environment: terraform` could mint
`repo:lentago/solidago:environment:terraform` and assume the write role. That
includes a PR branch's own edit of `terraform.yml`. "Only the `terraform.yml`
workflow" was never enforced.

The pipeline is now split by environment:

- The write role keeps the `environment:terraform` sub. The `terraform`
  environment carries a deployment branch policy, `main` only, that
  administrators cannot bypass. That policy is a GitHub-side check on the
  one input the OIDC gate cannot see, the ref. There is still no AWS-side
  boundary or SCP.
- PR plans run in a `terraform-plan` environment under a separate read-only
  role (`solidago-dev-github-actions-terraform-plan`: AWS `ReadOnlyAccess` plus
  state read and the lockfile).

The bare `pull_request` and `ref:refs/heads/main` subs were rejected as trusts.
Every pull-request or main-context job with `id-token: write` mints them,
including the Claude responder and reviewer workflows.

Per-resource least privilege remains out of scope by design. The
`trivy:ignore:AVD-AWS-0345` on the write role's `s3:*` stays and cites #225.
The plan role's reach into other stacks' state in the shared bucket is #240.

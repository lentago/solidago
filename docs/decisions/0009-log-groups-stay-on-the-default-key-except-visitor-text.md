# ADR-0009: CloudWatch log groups stay on the default key, except the one that holds visitor text

**Status:** Accepted (2026-11-02; [#246](https://github.com/lentago/solidago/issues/246), part of lentago/.github#318)

## Context

The 2026-11-02 security review noted that the platform's CloudWatch log groups
set no `kms_key_id`. CloudWatch Logs therefore encrypts them at rest with a
key AWS owns and manages. The alternative is the platform CMK,
`alias/solidago-dev-main`. Two facts shape the choice.

- **It costs almost nothing.** The CMK already exists and is already paid for.
  Its key policy already carries an `AllowCloudWatchLogs` statement for the
  logs service principal, scoped to this account's log groups (`modules/kms`),
  so no policy work is needed. CloudWatch Logs caches data keys, so the added
  KMS requests are negligible at this volume.
- **Its one real effect is on who can read.** With a CMK, a principal needs
  `kms:Decrypt` on the key as well as `logs:GetLogEvents` (or
  `FilterLogEvents`, `StartQuery`). `ReadOnlyAccess` grants the logs actions
  but not the key. Verified with `iam simulate-principal-policy`: the read-only
  Terraform plan role (#225) can read every log group today, and could not
  read one on the CMK. Its only `kms:Decrypt` on the main key is via Secrets
  Manager. Encryption at rest is equivalent either way.

So the question for each group is whether the people who hold read-only AWS
access should be able to read it. The plan role is one of them, and it is
reachable from any pull request's plan job.

The platform's log groups and what they hold:

| Log group | Module | What it holds |
|-----------|--------|---------------|
| `/aws/lambda/solidago-dev-pondview-ask` | `ask-lambda` | One `ask_query` line per question: outcome, latency, tokens, and **the visitor's question text** (up to 500 characters) |
| `/aws/lambda/solidago-dev-alb-log-shipper` | `alb-log-shipper` | The shipper's own run output; the ALB access records it forwards go to Axiom |
| `/ecs/solidago-dev-app`, `/ecs/solidago-dev-lentago`, `/ecs/solidago-dev-pondview` | `ecs`, `site` | The FireLens log router's own output; application logs go to Axiom while Axiom shipping is on |
| `/aws/vpc/flow-logs/solidago-dev` | `vpc` | VPC flow records: addresses, ports, byte counts |
| `/aws/cloudtrail/solidago-dev-trail` | `cloudtrail` (#244) | The management-event copy that feeds the CIS alarms; S3 holds the encrypted, validated original |

Container Insights' performance groups are created by AWS, not by this
repository, and are out of scope.

lentago/site-pondviewlane-com#24 decided to log the question text and named
the residual risk itself: "a resident could type an identifying detail into
the question itself (a neighbor's name, a specific address)". It bounded that
risk with short retention (this module keeps 30 days). Read access was not
part of that decision.

## Decision

1. **Decline a CMK for the operational groups.** That covers the shipper,
   the three ECS router groups, the VPC flow logs, and the CloudTrail copy.
   They hold telemetry that operators and read-only tooling are meant to
   read. Gating them behind the key would break read-only diagnosis without
   protecting anything sensitive. The CloudTrail events are already
   CMK-encrypted in their S3 archive, and the CloudWatch copy exists for the
   alarms. Flow records do carry client IP addresses. They are standard
   network telemetry, retained 30 days, and the people who read them are the
   people meant to.
2. **Use the platform CMK for the Ask log group**
   (`module.ask_pondview`, `log_kms_key_arn = module.kms.key_arn`). It is the
   one group whose content the public writes. From the apply on, every new
   event is under the key, so read-only principals, including the plan role,
   cannot read visitors' questions written after it. Events already in the
   group stay on the default key and stay readable to them until the 30-day
   retention ages them out. That was about 25 KB on 2026-11-02, written while
   the function answered 502. There is no added cost. Writing needs no
   change: CloudWatch Logs encrypts on write under the key policy above, and
   the function's role needs no KMS permission.

## Consequences

- Associating the key changes the existing group in place, and only new
  events are encrypted with it. Events written before the change stay on the
  default key until the 30-day retention ages them out.
- Reading the Ask log now needs `kms:Decrypt` on `alias/solidago-dev-main`.
  The maintainer's admin user and the apply role have it. Read-only tooling
  does not, by design.
- If the key is disabled or scheduled for deletion, CloudWatch Logs can no
  longer write to the Ask group, and the function's log lines are lost (the
  function itself keeps answering). The key is in the teardown runbook's KEEP
  set, so a routine teardown never touches it.

## Reversal condition

- **Toward a CMK:** move any other group onto the CMK when it starts holding
  content the public writes, personal data beyond network metadata, or
  secrets. Examples: application logs falling back to CloudWatch while Axiom
  shipping is off, if those logs carry request bodies or user identifiers; or
  a new function that logs user input.
- **Away from it:** move the Ask group off the CMK if the handler stops
  logging question text.

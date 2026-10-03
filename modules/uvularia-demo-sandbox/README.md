# modules/uvularia-demo-sandbox

A single-account fence for the **lentago/uvularia** demonstration "Ask" function
([lentago/uvularia#34](https://github.com/lentago/uvularia/issues/34)). The demo
runs in the same AWS account as the solidago platform — the only account we have
— but is scoped so it looks and behaves isolated from everything solidago owns.

> **Why single-account?** ADR-0007's no-multi-tenancy rule and plain honesty both
> want the demo's cloud footprint separable from the platform that serves
> lentago.dev. A client would do this in their own account; here the permissions
> boundary and the `uvularia-demo-` name prefix are what make the single-account
> version defensible. A separate member account under AWS Organizations is the
> stronger option and is noted for later — nothing in this module precludes it.

This module builds the **fence only**. The demo itself (the Lambda, its function
URL, any DynamoDB table, its runtime role and log group) is Terraformed from the
demo's own repo, **lentago/uvularia-demo-ask-rules**, which assumes the role
below via GitHub OIDC and applies *into* the fence.

```
lentago/uvularia-demo-ask-rules  ──OIDC──▶  uvularia-demo-ask-deploy  ──▶  Lambda, function URL,
   (its own terraform + state)              (capped by uvularia-demo-boundary)   DynamoDB, log group,
                                                                                 runtime role (boundary-bound)
```

## What this module creates

| Resource | Name | Purpose |
|----------|------|---------|
| OIDC role | `uvularia-demo-ask-deploy` | Assumed only by the rules repo (main + PRs). No access to anything solidago owns except one state key. |
| Permissions boundary | `uvularia-demo-boundary` | Hard ceiling on the deploy role and on every role it creates. |
| Deploy policy | `uvularia-demo-ask-deploy` | What the role may actually do (a subset of the boundary). |
| SNS topic (+ policy, email sub) | `uvularia-demo-alerts` | The sandbox's own alert channel — not solidago's. |
| Budget | `uvularia-demo` | $5/month, filtered to the `Project=uvularia-demo` tag. |
| Error alarm | `uvularia-demo-ask-errors` | Fires on the demo function's error count. |

Everything is tagged `Project = uvularia-demo` (overriding the provider's
`default_tags` on this account).

## What it isolates

- **Blast radius.** The deploy role can only touch Lambda, Lambda function URLs,
  IAM (roles/policies under the `uvularia-demo-` prefix, created only *with* this
  boundary), DynamoDB (`uvularia-demo-*` tables), SSM Parameter Store (read of
  `/uvularia-demo/*` only), and CloudWatch Logs (`/aws/lambda/uvularia-demo-*`).
  Nothing else — no VPC, RDS, ECS, S3 (beyond its state key), KMS (beyond the
  state CMK grant), Secrets Manager, Route 53, etc.
- **Self-propagating boundary.** `iam:CreateRole` is allowed only when the new
  role carries `uvularia-demo-boundary` *and* a `uvularia-demo-` name. So the
  function's runtime role is fenced too — even if the rules repo tried to attach
  `AdministratorAccess` to it, the boundary caps it back to the sandbox.
- **State.** The role may read/write exactly one object —
  `uvularia-demo/ask.tfstate` in `solidago-tfstate-<account>` — plus that key's
  two DynamoDB lock rows (`…/ask.tfstate` and `…/ask.tfstate-md5`), with a KMS
  grant on the state CMK limited the same way. It cannot read solidago's state or
  any other repo's.
- **Alerts.** Budget and alarm publish to the sandbox's own SNS topic, not the
  platform's.

## What it cannot isolate

It is the **same AWS account, the same bill, and the same region** as solidago.
The budget is a tag-filtered view of one shared invoice, not a separate account's
spend. IAM is account-global, so the fence is a set of scoped grants, not a wall.
Account-level controls (SCPs, root, Organizations) are unavailable with one
account. If true isolation is ever required, lift this into a dedicated member
account — the shape here (one deploy role, one boundary, one state key) ports
directly.

## The secret slot, not the secret

The demo function reads its Anthropic key from the SSM SecureString parameter:

```
/uvularia-demo/anthropic-api-key
```

**Terraform does not create or store this parameter.** The path is documented and
the runtime role is granted read on it (via the boundary), but the value is
written by hand so it never lands in Terraform state or a repo. Create it once,
out of band:

```bash
aws ssm put-parameter \
  --name /uvularia-demo/anthropic-api-key \
  --type SecureString \
  --value 'sk-ant-…' \
  --region us-east-1
# rotate later with the same command plus --overwrite
```

(`exported` as `uvularia_demo_anthropic_api_key_parameter_path` from
`environments/dev`.)

## One-time billing step for the budget

The `uvularia-demo` budget filters on the `Project` cost-allocation tag. Activate
it once in **Billing → Cost allocation tags → User-defined tags → `Project`**
(console only; it cannot be Terraformed). Until activated, the budget sees `$0`
and simply never alarms — it does not false-fire.

## Inputs

| Name | Default | Description |
|------|---------|-------------|
| `project`, `environment` | — | Host-platform context (the sandbox names itself `uvularia-demo-*`, not from these). |
| `aws_account_id`, `aws_region` | — | For ARN construction. |
| `oidc_provider_arn` | — | The account's shared GitHub OIDC provider (`module.iam.github_oidc_provider_arn`). |
| `tfstate_kms_key_arn` | — | The bootstrap-managed state CMK (`alias/solidago-tfstate`). |
| `github_org` | `lentago` | Org that owns the rules repo. |
| `rules_repo` | `uvularia-demo-ask-rules` | The only trusted repo. |
| `anthropic_api_key_parameter_name` | `/uvularia-demo/anthropic-api-key` | Documented SSM path (not created by TF). |
| `alert_email` | `cpitzi@gmail.com` | Budget + alarm email (confirm the SNS subscription after apply). |
| `monthly_budget_amount` | `5` | USD/month. |
| `budget_alert_thresholds` | `[80, 100]` | Percent-of-budget alert points. |
| `function_name` | `uvularia-demo-ask` | Lambda the error alarm watches (created by the rules repo). |
| `error_alarm_threshold` | `1` | Errors (Sum / 5 min) above which the alarm fires. |

## Outputs

| Name | Description |
|------|-------------|
| `deploy_role_arn` | Role the rules repo assumes via OIDC. |
| `permissions_boundary_arn` | Boundary the rules repo must attach to every role it creates. |
| `state_key` | The one S3 state key the role may use. |
| `anthropic_api_key_parameter_path` | SSM path for the hand-written key. |

## Deleting the whole sandbox in one apply

The fence is self-contained: remove the `module "uvularia_demo_sandbox"` block
(and its four outputs) from `environments/dev/`, then `terraform apply`. Every
resource here is destroyed in that single apply.

**Tear down the demo first.** The Lambda, DynamoDB table, runtime role, etc. live
in the *rules repo's* state, not here. Run `terraform destroy` from
lentago/uvularia-demo-ask-rules **before** removing this fence — otherwise those
resources are orphaned (the deploy role that could manage them is gone) and must
be cleaned up by hand. The hand-written SSM parameter also survives; delete it
with `aws ssm delete-parameter --name /uvularia-demo/anthropic-api-key` if you
want it gone.

#!/bin/bash
# Run this from your terminal to create all backlog issues

# 1. Resource naming standardization (from Phase 4b)
gh issue create --repo lentago/foundry-platform-demo \
  --title "Standardize Terraform resource naming convention (this vs main)" \
  --body "## Context
During Phase 4b (S3 module), we noticed inconsistent internal Terraform resource naming across modules:
- S3 module uses \`this\` (e.g., \`aws_s3_bucket.this\`)
- RDS module uses \`main\` (e.g., \`aws_db_instance.main\`)
- Earlier Phase 2 modules may vary

## Action
Pick one convention and apply it across all modules.

## Notes
- \`this\` is the convention used by official \`terraform-aws-modules\` repos
- \`main\` is more self-documenting for newcomers
- Requires \`terraform state mv\` for each renamed resource to avoid destroy/recreate

## Priority
Low — cleanup task, no functional impact."

# 2. DynamoDB lock table deprecation (shows every plan/apply)
gh issue create --repo lentago/foundry-platform-demo \
  --title "Replace deprecated dynamodb_table backend param with use_lockfile" \
  --body "## Context
Every \`terraform plan\` and \`apply\` shows:
\`\`\`
Warning: Deprecated Parameter
The parameter \"dynamodb_table\" is deprecated. Use parameter \"use_lockfile\" instead.
\`\`\`

## Action
1. In \`environments/dev/backend.tf\`, replace \`dynamodb_table\` with \`use_lockfile = true\`
2. Run \`terraform init -reconfigure\`
3. Research whether the DynamoDB table can be decommissioned after migration

## Priority
Medium — warning on every operation, will eventually become an error."

# 3. Selective destroy strategy (discussed in Phase 2 and Phase 3)
gh issue create --repo lentago/foundry-platform-demo \
  --title "Implement selective teardown/standup scripts for cost management" \
  --body "## Context
Full \`terraform destroy\` saves ~\$4.50/day in idle costs but causes 15-20 minute resurrection pain due to:
- KMS key recovery windows (30 days)
- Secrets Manager recovery windows (7 days)
- ECR image deletion requiring re-push
- Route 53 NS delegation requiring manual reconfiguration

## Proposal
Create \`scripts/teardown.sh\` and \`scripts/standup.sh\` that selectively manage expensive resources:

**Destroy nightly (expensive):**
- NAT Gateways (~\$2.15/day)
- ALB (~\$0.65/day)
- ECS Fargate tasks (~\$0.80/day)
- RDS instance (~\$0.93/day)

**Keep running (cheap, painful to recreate):**
- KMS key (\$0.03/day)
- Secrets Manager (\$0.01/day)
- Route 53 zone (\$0.02/day)
- CloudWatch log groups (pennies)
- ECR repo with images (pennies)
- IAM roles/policies (free)
- Security groups (free)

## Notes
- Could use \`terraform destroy -target\` or Terraform workspaces
- Alternative: Terraform variable to toggle expensive resources on/off
- RDS supports stop/start (up to 7 days) as an alternative to destroy

## Priority
Medium — saves money and time on every session."

# 4. State bucket encryption upgrade (Decision #2 from Phase 0)
gh issue create --repo lentago/foundry-platform-demo \
  --title "Upgrade state bucket encryption from AES256 to KMS CMK" \
  --body "## Context
Decision #2 from Phase 0: the Terraform state bucket uses default AES256 encryption to avoid a KMS dependency before Phase 2. Now that the KMS key exists, the bucket should be upgraded to use the CMK for consistency.

## Action
Update the state bucket server-side encryption configuration to use the KMS CMK (key alias: \`alias/foundry-dev-main\`).

## Notes
- This is a bootstrap resource managed outside Terraform
- Requires \`aws s3api put-bucket-encryption\` CLI command
- Existing objects remain AES256-encrypted; new objects use KMS
- Consider adding this to the bootstrap script for future environments

## Priority
Low — AES256 is still encrypted, just not with our managed key."

# 5. VPC subnet refactor: count → for_each (Decision #4 from Phase 0)
gh issue create --repo lentago/foundry-platform-demo \
  --title "Refactor VPC subnets from count to for_each" \
  --body "## Context
Decision #4 from Phase 0: VPC subnets use \`count\` for simplicity. \`for_each\` provides better state handling — removing a subnet from the middle of a list with \`count\` causes all subsequent subnets to be destroyed and recreated with new indices.

## Action
Refactor \`modules/vpc/main.tf\` subnet resources from \`count\` to \`for_each\` using a map keyed by AZ name.

## Notes
- Requires \`terraform state mv\` to remap existing resources
- Affects public, app, and data subnets (6 resources total)
- Should be done during a full destroy/apply cycle to minimize risk

## Priority
Low — no functional impact unless AZs are added/removed."

# 6. GitHub Actions Node.js 20 deprecation
gh issue create --repo lentago/foundry-platform-demo \
  --title "Upgrade GitHub Actions to Node.js 24-compatible versions" \
  --body "## Context
GitHub is deprecating Node.js 20 in Actions runners. Current workflow uses:
- \`actions/checkout@v4\`
- \`actions/setup-node@v4\`
- \`aws-actions/configure-aws-credentials@v4\`

These will need to move to versions that support Node 24 before June 2026.

## Action
Monitor for v5 releases of these actions and update \`.github/workflows/deploy.yml\` when available.

## Notes
- Warning appears in CI logs but doesn't block builds yet
- Deadline is approximately June 2026
- Check: https://github.com/actions/checkout/releases

## Priority
Medium — has a deadline (June 2026)."

# 7. Local Docker Engine setup on ChromeOS
gh issue create --repo lentago/foundry-platform-demo \
  --title "Set up local Docker Engine on ChromeOS for local container builds" \
  --body "## Context
Currently relying entirely on CI/CD for container builds because the Docker Engine isn't installed in the ChromeOS Crostini environment. Only the Docker CLI is present. CPU supports nested virtualization (\`vmx\` flags present).

## Action
Install Docker Engine in Crostini, or set up Podman as a daemon-less alternative.

## Notes
- \`vmx\` flags confirmed present — nested virtualization is supported
- Podman is a drop-in replacement that doesn't need a daemon
- Not blocking anything — CI/CD handles all builds currently
- Useful for local testing and debugging

## Priority
Low — CI/CD path works, this is a convenience improvement."

# 8. Multi-domain architecture
gh issue create --repo lentago/foundry-platform-demo \
  --title "Design multi-domain architecture for portfolio sites" \
  --body "## Context
Multiple domains planned for the platform:
- \`icecreamtofightwith.com\` — cookbook (currently active)
- \`chrispitzi.com\` or \`cpitzi.com\` — professional marketing site
- \`hellavisible.net\` — activism/nonprofit concept (domain owned)
- \`pitzilabs.dev\` or similar — technical platform brand

Currently the infrastructure serves a single site. Need to design for multiple sites on the same platform.

## Questions to Resolve
- Separate ECS services per site, or single service with routing?
- CloudFront CDN for static sites vs ALB-only?
- Shared ALB with host-based routing vs separate ALBs?
- Multi-domain ACM certificate vs per-domain certs?

## Priority
Medium — architectural decision needed before Phase 7 hardening."

# 9. RDS-managed password migration to traditional (potential Phase 7)
gh issue create --repo lentago/foundry-platform-demo \
  --title "Document: Phase 2 Secrets Manager secret unused after RDS-managed password choice" \
  --body "## Context
The Phase 2 Secrets Manager secret (\`foundry-dev/db-credentials\`) is a placeholder that was originally intended for RDS credentials. We chose RDS-managed passwords instead (Decision #19), so this secret is now orphaned.

## Options
1. Leave it — costs \$0.40/mo, not hurting anything
2. Repurpose it for application-level secrets (API keys, etc.)
3. Remove it (requires updating IAM policies that reference it)

## Priority
Low — no functional impact, minimal cost."

echo ""
echo "All issues created! Check https://github.com/PitziLabs/foundry-platform-demo/issues"

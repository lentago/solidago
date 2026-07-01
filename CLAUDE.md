# CLAUDE.md — Foundry Platform

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a
brief self-introduction as **Platform Claude** — Terraform steward for the
foundry AWS infrastructure platform (networking, IAM/OIDC, secrets,
compute, data, observability, CI/CD). One sentence is plenty; don't make
a meal of it.

## Project Overview

Foundry Platform — Terraform-based IaC project building a production-grade, three-tier AWS environment. All phases (networking, encryption, IAM, secrets, compute/containers, data, observability, CI/CD, security hardening) are complete.

## Common Commands

```bash
# One-time backend bootstrap (creates S3 bucket + DynamoDB table)
./scripts/bootstrap/bootstrap-backend.sh

# Initialize Terraform
cd environments/dev && terraform init

# Plan changes
terraform plan -out=tfplan

# Apply changes
terraform apply tfplan

# Validate configuration without accessing remote state
terraform validate

# Format check
terraform fmt -check -recursive

# View outputs
terraform output

```

Container image builds happen in the workload repo's deploy workflow (see [ice-cream-book](https://github.com/lentago/ice-cream-book)/.github/workflows/deploy.yml), not from this repo. This repo manages the ECR registry, ECS cluster/service, and IAM trust — not the image itself.

All Terraform commands run from `environments/dev/` (the only environment entry point currently).

## Quick Reference

| Item | Value |
|------|-------|
| Terraform version | >= 1.0 |
| AWS provider | ~> 5.0 (locked at 5.100.0) |
| AWS region | us-east-1 |
| AWS profile | `default` — provider uses the default credential chain; no `foundry` profile exists |
| Domain | icecreamtofightwith.com |
| GitHub org/repo | lentago/foundry-platform-demo |
| State bucket | foundry-tfstate-`<ACCOUNT_ID>` |
| State locking | S3-native (`use_lockfile = true`) |
| AZs | us-east-1a, us-east-1b |

## Network Layout

| Tier | Subnets | CIDRs | Purpose |
|------|---------|-------|---------|
| Public | 2 | 10.0.1.0/24, 10.0.2.0/24 | ALB, NAT Gateways |
| App | 2 | 10.0.10.0/24, 10.0.11.0/24 | ECS Fargate tasks (private) |
| Data | 2 | 10.0.20.0/24, 10.0.21.0/24 | RDS, ElastiCache (private) |

Each AZ has its own NAT Gateway.

## Module Dependency Graph

```
VPC ──┐
      ├──→ Security Groups ──→ ALB ──┐
KMS ──┤                              ├──→ ECS ──→ ECS Autoscaling
      ├──→ Secrets ──→ IAM ──────────┘     ↑
      └──→ IAM (bidirectional with KMS)    │
                                           │
ECR ───────────────────────────────────────┘
DNS ←──→ ALB (certificate ↔ alias record)
```

**Bidirectional dependencies to watch:**
- **KMS ↔ IAM**: IAM needs KMS key ARN for decrypt permissions; KMS key policy needs IAM role ARNs to grant access.
- **DNS ↔ ALB**: DNS provides ACM certificate to ALB; ALB provides its DNS name/zone ID back for the Route 53 alias record.

## Architecture Conventions

**Naming**: `{project}-{environment}-{resource-type}` (e.g., `foundry-dev-ecs-cluster`).

**Tagging**: Applied via provider `default_tags` in `environments/dev/main.tf` (`Environment`, `Project`, `ManagedBy`). Individual resources add a `Name` tag.

**Module structure**: Every module has exactly `main.tf`, `variables.tf`, `outputs.tf`. Every module accepts `environment` and `project` variables.

**Security groups**: Rules reference security group IDs (not CIDRs) for Fargate compatibility. Groups are created as empty shells first, then rules are added as separate `aws_security_group_rule` resources to avoid circular references.

**`ignore_changes` patterns**:
- ECS service ignores `task_definition` and `desired_count` so CI/CD and auto-scaling can manage independently.
- Secrets Manager ignores `secret_string` to prevent Terraform from overwriting manual/automated rotations.

## Adding a New Module

1. Create `modules/<name>/` with `main.tf`, `variables.tf`, `outputs.tf`
2. Include `environment` and `project` variables for consistent naming/tagging
3. Wire it into `environments/dev/main.tf` following the dependency graph order
4. Export relevant outputs in `environments/dev/outputs.tf`

## Implementation Workflow

PR workflow + auto-merge arming protocol is fleet-wide; see `~/repos/CLAUDE.md`.

## Key Files for Context

- `environments/dev/main.tf` — how all modules connect (the orchestration layer)
- `environments/dev/outputs.tf` — what each module exposes
- `environments/dev/backend.tf` — remote state configuration (S3 + DynamoDB)
- `modules/*/variables.tf` — what each module accepts
- `modules/iam/main.tf` — OIDC roles. `foundry-dev-github-actions` (trusts the workload repo `ice-cream-book` via `var.app_github_repo`) deploys containers and updates ECS; `foundry-dev-github-actions-terraform` (trusts this repo's `terraform` environment) runs the Terraform pipeline. The split keeps platform mutations and workload deploys on separate credentials.

## Project Phases

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Bootstrap backend, project structure | Complete |
| 1 | VPC, KMS, Secrets Manager | Complete |
| 2 | IAM roles, Security Groups | Complete |
| 3 | ECR, DNS/ACM, ALB, ECS Fargate, Auto-Scaling | Complete |
| 4 | RDS PostgreSQL, ElastiCache Redis | Complete |
| 5 | CloudWatch monitoring, alarms | Complete |
| 6 | GitHub Actions CI/CD workflows | Complete |
| 7 | WAF, Shield, GuardDuty | Complete |

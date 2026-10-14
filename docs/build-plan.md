# AWS Infrastructure — Build Plan

## Project Overview

**Goal:** Build a production-style AWS environment, fully Terraform-managed and GitHub-hosted, ready to run a containerized application — with real architectural rigor baked in from the start.

**Principles:** Fault tolerance, redundancy, operability, observability, security by default, infrastructure as code.

**Tools:** Terraform, GitHub (with Actions for CI/CD), AWS CLI v2, Docker, kubectl.

**Target Outcome:** A portfolio-grade cloud environment demonstrating mastery of ~19 AWS services with legitimate architectural purpose — not checkbox tourism. The infrastructure serves as a platform for an as-yet-unknown containerized application.

---

## Architecture Summary

A classic three-tier architecture deployed across multiple Availability Zones:

- **Presentation tier:** Application Load Balancer (public subnets) with WAF, TLS via ACM, DNS via Route 53
- **Application tier:** ECS Fargate containers (private subnets) with auto-scaling
- **Data tier:** RDS PostgreSQL Multi-AZ + ElastiCache Redis (private subnets)

Supporting infrastructure: VPC networking, IAM, KMS encryption, Secrets Manager, CloudWatch observability, CloudTrail auditing, AWS Config compliance, S3 for storage, and GitHub Actions for CI/CD.

---

## Phase 0: Foundation & Tooling

**Goal:** Local environment ready, accounts created, version control established.

### Steps

1. **AWS Account setup** — Use a fresh account or dedicated sandbox. Enable MFA on root immediately. Create an IAM admin user for daily work (never use root again).

2. **Install tooling locally:**
   - Terraform (use `tfenv` for version management)
   - AWS CLI v2
   - Docker
   - `kubectl`
   - `git`

3. **Create GitHub repo** — Name: `foundry-platform-demo`. Initialize with:
   - `.gitignore` (Terraform-specific)
   - `README.md`
   - `docs/` folder for decision journaling (ADRs — Architecture Decision Records)

4. **Bootstrap Terraform backend** — Create S3 bucket + DynamoDB lock table for remote state. This is a chicken-and-egg problem; bootstrap it with a small shell script or one-time AWS CLI calls.

5. **Establish Terraform directory structure:**
   ```
   foundry-platform-demo/
   ├── environments/
   │   └── dev/
   │       ├── main.tf
   │       ├── variables.tf
   │       ├── outputs.tf
   │       ├── terraform.tfvars
   │       └── backend.tf
   ├── modules/
   │   ├── vpc/
   │   ├── ecs/
   │   ├── rds/
   │   ├── elasticache/
   │   ├── alb/
   │   ├── security/
   │   ├── monitoring/
   │   └── cicd/
   ├── scripts/
   │   └── bootstrap/
   ├── docs/
   │   └── decisions/
   ├── .github/
   │   └── workflows/
   ├── .gitignore
   └── README.md
   ```
   Modules for reusability, environment folders for state isolation.

### Completion Criteria
- [ ] AWS account with MFA-enabled root, IAM admin user configured
- [ ] All CLI tools installed and verified (`terraform --version`, `aws sts get-caller-identity`, etc.)
- [ ] GitHub repo created with directory structure
- [ ] Terraform S3 backend + DynamoDB lock table bootstrapped
- [ ] First commit pushed

---

## Phase 1: Networking (VPC + Subnets)

**Goal:** Establish the network foundation with fault tolerance across Availability Zones.

**AWS Services:** VPC, Subnets, Internet Gateway, NAT Gateway, Route Tables, VPC Flow Logs

### Steps

6. **VPC** — CIDR block sized for growth (e.g., `10.0.0.0/16`).

7. **Subnets across 2+ AZs:**
   - Public subnets (for ALB, bastion/debugging) — e.g., `10.0.1.0/24`, `10.0.2.0/24`
   - Private subnets for application tier — e.g., `10.0.10.0/24`, `10.0.11.0/24`
   - Private subnets for data tier — e.g., `10.0.20.0/24`, `10.0.21.0/24`

8. **Internet Gateway** attached to VPC for public subnet routing. **NAT Gateway** in each AZ (one per public subnet) for private subnet outbound access — this is the HA pattern.

9. **Route tables** wired correctly:
   - Public route table → `0.0.0.0/0` to IGW
   - Private route tables (per AZ) → `0.0.0.0/0` to the AZ-local NAT Gateway

10. **VPC Flow Logs** to CloudWatch — observability starts at the network layer.

### Architectural Decisions
- **Why separate data and app subnets?** Network ACLs can be applied differently. Database subnets get registered in an RDS subnet group.
- **Why NAT per AZ?** If one AZ's NAT goes down, the other AZ's private subnets still have outbound access. Single NAT is a single point of failure.

### Completion Criteria
- [ ] VPC created with correct CIDR
- [ ] 6 subnets across 2 AZs (2 public, 2 app-private, 2 data-private)
- [ ] IGW and NAT Gateways deployed
- [ ] Route tables correctly associated
- [ ] Flow logs enabled and delivering to CloudWatch
- [ ] `terraform plan` is clean, `terraform apply` succeeds

---

## Phase 2: Security Scaffolding

**Goal:** Establish identity, access, encryption, and secrets management before any workloads exist.

**AWS Services:** IAM, Security Groups, KMS, Secrets Manager

### Steps

11. **IAM roles & policies:**
    - Terraform execution role
    - ECS task execution role (pulls images, writes logs)
    - ECS task role (what the app itself can do)
    - GitHub Actions OIDC role (for CI/CD — no long-lived keys)
    - Principle of least privilege from day one.

12. **Security Groups** as Terraform modules:
    - ALB SG: inbound 443 from `0.0.0.0/0`, outbound to App SG
    - App SG: inbound from ALB SG only, outbound to Data SG + NAT
    - Data SG (RDS): inbound from App SG only on port 5432
    - Data SG (Redis): inbound from App SG only on port 6379
    - Explicit references between groups — no CIDR-based rules for internal traffic.

13. **KMS customer-managed key** — single key for encrypting RDS, S3, Secrets Manager, EBS, CloudWatch Logs. Key policy allows the relevant IAM roles.

14. **Secrets Manager** — Create the pattern even before you have secrets. Wire up a placeholder secret (e.g., future DB credentials). ECS task role gets read access.

### Architectural Decisions
- **Why OIDC for GitHub Actions?** Eliminates long-lived AWS access keys. GitHub proves its identity via JWT, AWS trusts the GitHub OIDC provider.
- **Why customer-managed KMS?** Control over key rotation, key policies, and audit trail. AWS-managed keys work but give you less control.

### Completion Criteria
- [ ] IAM roles created with minimal policies
- [ ] Security groups created with correct ingress/egress chains
- [ ] KMS key created and accessible by required roles
- [ ] Secrets Manager secret created with placeholder value
- [ ] No security group rules reference `0.0.0.0/0` except ALB inbound on 443

---

## Phase 3: Compute & Container Platform

**Goal:** Deploy a containerized application with load balancing, TLS, DNS, and auto-scaling.

**AWS Services:** ECS (Fargate), ECR, Application Load Balancer, Route 53, ACM

### Steps

15. **ECR repository** — Container image registry. Enable image scanning on push.

16. **ECS Cluster on Fargate:**
    - Cluster definition
    - Task definition with a placeholder image (`nginx` or `httpd`)
    - Service with desired count of 2 (one per AZ for HA)
    - Tasks run in private app subnets
    - Task execution role for image pull + log writing
    - Task role for app-level AWS access

17. **Application Load Balancer:**
    - Deployed in public subnets
    - HTTPS listener (port 443) with ACM certificate
    - HTTP listener (port 80) redirects to HTTPS
    - Target group pointing to ECS tasks with health checks configured
    - Connection draining enabled

18. **Route 53:**
    - Hosted zone for your domain (register a cheap `.link` or `.click` domain, or use a subdomain)
    - A record aliased to ALB

19. **ACM certificate** — Free TLS cert for your domain. Use DNS validation (automated via Route 53).

20. **Auto-scaling policy** on ECS service:
    - Target tracking on CPU utilization (e.g., 70%)
    - Optional: target tracking on memory
    - Min: 2 tasks, Max: 6 tasks (keep costs bounded)

### Architectural Decisions
- **Why Fargate over EC2?** No instance management, patching, or capacity planning. Perfect for an environment where you want to focus on architecture, not OS maintenance.
- **Why 2 minimum tasks?** One per AZ ensures the app survives an AZ failure.

### Completion Criteria
- [ ] ECR repo created, placeholder image pushed
- [ ] ECS cluster, task definition, and service running
- [ ] ALB serving HTTPS with valid certificate
- [ ] DNS resolving to ALB
- [ ] Health checks passing
- [ ] Auto-scaling policy active
- [ ] Can `curl https://yourdomain.tld` and get a response

---

## Phase 4: Data Layer

**Goal:** Add persistent storage with encryption, backups, and high availability.

**AWS Services:** RDS (PostgreSQL), S3, ElastiCache (Redis)

### Steps

21. **RDS PostgreSQL (or Aurora PostgreSQL):**
    - Multi-AZ deployment in data-tier private subnets
    - DB subnet group from data subnets
    - Encrypted at rest with KMS key
    - Automated backups enabled (7-day retention minimum)
    - Credentials stored in Secrets Manager
    - Performance Insights enabled (free tier available)
    - Instance class: `db.t3.micro` or `db.t4g.micro` for this environment

22. **S3 bucket:**
    - For static assets, logs, future app storage
    - Versioning enabled
    - Server-side encryption with KMS key
    - Public access explicitly blocked (all four block settings)
    - Lifecycle rules for log rotation

23. **ElastiCache Redis cluster:**
    - Deployed in data-tier private subnets
    - Encryption in transit and at rest
    - Single node for this environment (Multi-AZ replication available if budget allows)
    - Parameter group with sensible defaults

### Architectural Decisions
- **Why PostgreSQL?** Most versatile open-source RDBMS. Aurora is fancier but costs more; standard RDS is fine for this environment.
- **Why Redis?** Session caching, rate limiting, pub/sub — Redis is the Swiss Army knife of the data tier.

### Completion Criteria
- [ ] RDS instance running, accessible from ECS tasks
- [ ] DB credentials in Secrets Manager, accessible via ECS task role
- [ ] S3 bucket created with encryption, versioning, and access blocked
- [ ] ElastiCache Redis reachable from app subnets
- [ ] All data-tier resources encrypted with KMS key

---

## Phase 5: Observability & Operations

**Goal:** See what's happening, get alerted when things go wrong, maintain an audit trail.

**AWS Services:** CloudWatch (Logs, Metrics, Alarms), SNS, CloudTrail, AWS Config

### Steps

24. **CloudWatch Log Groups:**
    - ECS task logs (application output)
    - VPC Flow Logs
    - RDS slow query logs
    - Retention policy set (e.g., 30 days for this environment)

25. **CloudWatch Alarms tied to SNS:**
    - ECS CPU > 80%
    - ECS memory > 80%
    - ALB 5xx error rate > 1%
    - ALB target response time > 2s
    - RDS CPU > 80%
    - RDS free storage < 20%
    - SNS topic delivers alarm notifications to your email

26. **CloudTrail:**
    - Enabled for all management events in the account
    - Logs delivered to the S3 bucket (separate prefix)
    - This is your audit trail for every API call

27. **AWS Config:**
    - Enabled with a recorder
    - Managed rules for baseline compliance:
      - S3 buckets must be encrypted
      - Security groups must not allow unrestricted SSH
      - RDS instances must be encrypted
      - CloudTrail must be enabled
    - Demonstrates governance awareness

### Completion Criteria
- [ ] All log groups created and receiving data
- [ ] Alarms configured and tested (trigger one manually)
- [ ] SNS email notification confirmed
- [ ] CloudTrail enabled and logging to S3
- [ ] AWS Config rules deployed and evaluating

---

## Phase 6: CI/CD Pipeline

**Goal:** Automated, secure deployment pipeline from code push to running containers.

**AWS Services:** ECR (image push), ECS (deployment target)
**External Services:** GitHub Actions (free tier)

### Steps

28. **Application deployment workflow** (`.github/workflows/deploy.yml`):
    - Trigger: push to `main` branch
    - Authenticate to AWS via OIDC (no stored credentials)
    - Build Docker image
    - Push to ECR
    - Update ECS service to deploy new task definition
    - Wait for deployment to stabilize

29. **Terraform CI workflow** (`.github/workflows/terraform.yml`):
    - On PR: `terraform fmt -check`, `terraform validate`, `terraform plan` (output as PR comment)
    - On merge to `main`: `terraform apply -auto-approve`
    - OIDC authentication to AWS

30. **Branch protection rules on `main`:**
    - Require pull request reviews
    - Require status checks to pass (Terraform plan, lint)
    - No direct pushes

### Architectural Decisions
- **Why GitHub Actions over CodePipeline?** Free, widely understood, better developer experience. CodePipeline is AWS-native but adds cost and complexity for this environment.
- **Why OIDC over IAM keys?** No secrets to rotate, no keys to leak. GitHub's identity provider is trusted by your AWS account.

### Completion Criteria
- [ ] Deploy workflow pushes image and updates ECS on merge
- [ ] Terraform workflow plans on PR and applies on merge
- [ ] Branch protection rules enforced
- [ ] End-to-end: PR → review → merge → deploy → live

---

## Phase 7: Hardening & Polish

**Goal:** Production-readiness touches that demonstrate security and operational maturity.

### Steps

31. **WAF on ALB:**
    - AWS managed rule groups (Core Rule Set, Known Bad Inputs)
    - Rate-limiting rule (e.g., 2000 requests/5 minutes per IP)
    - Logging to CloudWatch

32. **AWS Budgets & Cost Alerts:**
    - Monthly budget alarm (e.g., $200/month)
    - Forecasted spend alarm
    - Email notification via SNS

33. **Tagging strategy — every resource gets:**
    - `Environment` = dev
    - `Project` = foundry
    - `ManagedBy` = terraform
    - Enforce via AWS Config rules and/or Terraform `default_tags`

34. **Documentation pass:**
    - Architecture diagram (draw.io, Mermaid, or Lucidchart)
    - Decision log in `docs/decisions/` (ADR format)
    - `README.md` with "deploy from scratch" instructions
    - Cost estimate for running vs. parked state

---

## AWS Services Summary

| # | Service | Purpose | Phase |
|---|---------|---------|-------|
| 1 | VPC | Network isolation | 1 |
| 2 | Subnets | AZ distribution, tier separation | 1 |
| 3 | Internet Gateway | Public internet access | 1 |
| 4 | NAT Gateway | Private subnet outbound | 1 |
| 5 | IAM | Identity and access management | 2 |
| 6 | KMS | Encryption key management | 2 |
| 7 | Secrets Manager | Credential storage | 2 |
| 8 | ECS (Fargate) | Container orchestration | 3 |
| 9 | ECR | Container image registry | 3 |
| 10 | ALB | Load balancing | 3 |
| 11 | Route 53 | DNS | 3 |
| 12 | ACM | TLS certificates | 3 |
| 13 | RDS | Relational database | 4 |
| 14 | S3 | Object storage | 4 |
| 15 | ElastiCache | In-memory caching | 4 |
| 16 | CloudWatch | Logs, metrics, alarms | 5 |
| 17 | SNS | Notifications | 5 |
| 18 | CloudTrail | API audit logging | 5 |
| 19 | AWS Config | Compliance monitoring | 5 |
| 20 | WAF | Web application firewall | 7 |
| 21 | Budgets | Cost management | 7 |

---

## Cost Management

**Estimated running cost:** $150–250/month with all services active.

**Major cost drivers:**
- NAT Gateways (~$65/month for 2)
- RDS Multi-AZ (~$30–60/month for t3.micro)
- ALB (~$20–25/month)
- ElastiCache (~$15–25/month)

**Cost reduction strategies:**
- `terraform destroy` when not actively working
- Build a "parking" Terraform workspace that scales down non-essential resources
- Use Fargate Spot for non-production tasks
- Consider single NAT Gateway during development (accept the SPOF temporarily)

---

## Progress Tracker

| Phase | Status | Started | Completed |
|-------|--------|---------|-----------|
| 0 — Foundation & Tooling | Not Started | | |
| 1 — Networking | Not Started | | |
| 2 — Security | Not Started | | |
| 3 — Compute & Containers | Not Started | | |
| 4 — Data Layer | Not Started | | |
| 5 — Observability | Not Started | | |
| 6 — CI/CD | Not Started | | |
| 7 — Hardening | Not Started | | |

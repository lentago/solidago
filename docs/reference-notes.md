# Foundry Platform — Central Reference Notes

> **This is a living document.** Update it as each phase progresses. Upload to your Claude Project knowledge base so every conversation has context.

---

## Account & Identity

| Item | Value | Notes |
|------|-------|-------|
| AWS Account ID | `<ACCOUNT_ID>` — run `aws sts get-caller-identity --query Account --output text` | |
| AWS Region | us-east-1 | |
| Root email | _TBD_ | MFA enabled: ✅ |
| IAM admin username | cpitzi-iac | MFA enabled: ✅ |
| AWS CLI profile name | foundry | |
| GitHub repo | foundry-platform-demo | https://github.com/lentago/foundry-platform-demo |
| GitHub username | cpitzi | |
| Domain name | _TBD_ | Cheap domain, Phase 3 |
| Local OS | ChromeOS w/ Linux dev env (Debian-based) | |

---

## Terraform Backend

| Item | Value |
|------|-------|
| State bucket name | foundry-tfstate-`<ACCOUNT_ID>` |
| State bucket region | us-east-1 |
| DynamoDB lock table | foundry-tfstate-lock |
| State file key | env/dev/terraform.tfstate |

---

## Networking (Phase 1)

| Item | Value |
|------|-------|
| VPC ID | vpc-00c7c8f9950ad6468 |
| VPC CIDR | 10.0.0.0/16 |
| AZ 1 | us-east-1a |
| AZ 2 | us-east-1b |
| Public subnet AZ1 | subnet-0677e44d31c8df6ff (10.0.1.0/24) |
| Public subnet AZ2 | subnet-07f793a7266da9a86 (10.0.2.0/24) |
| App-private subnet AZ1 | subnet-055e06ee5000e35c1 (10.0.10.0/24) |
| App-private subnet AZ2 | subnet-01354c329bfdeec58 (10.0.11.0/24) |
| Data-private subnet AZ1 | subnet-0ede14a937169580e (10.0.20.0/24) |
| Data-private subnet AZ2 | subnet-05c868aa8fdf71042 (10.0.21.0/24) |
| NAT Gateway AZ1 IP | 32.192.220.190 |
| NAT Gateway AZ2 IP | 98.90.48.147 |

---

## Security (Phase 2)

| Item | Value |
|------|-------|
| KMS key alias | alias/foundry-dev-main |
| KMS key ID | 366ef9e5-645c-4755-9ad6-4b2ea322af9e |
| KMS key ARN | arn:aws:kms:us-east-1:`<ACCOUNT_ID>`:key/`<KEY_ID>` |
| ECS task execution role | arn:aws:iam::`<ACCOUNT_ID>`:role/foundry-dev-ecs-task-execution |
| ECS task role | arn:aws:iam::`<ACCOUNT_ID>`:role/foundry-dev-ecs-task |
| GitHub Actions OIDC role | arn:aws:iam::`<ACCOUNT_ID>`:role/foundry-dev-github-actions |
| Secrets Manager secret name | foundry-dev/db-credentials |
| Secrets Manager secret ARN | arn:aws:secretsmanager:us-east-1:`<ACCOUNT_ID>`:secret:foundry-dev/db-credentials-`<SUFFIX>` |
| ALB security group | sg-09d6b29de9879301c |
| App security group | sg-0e31af3dc8ce08f3a |
| RDS security group | sg-08a72bc492fa4fea0 |
| Redis security group | sg-034ba24499da8d804 |

---

## Compute & Containers (Phase 3)

| Item | Value |
|------|-------|
| ECR repo name | foundry-dev-app |
| ECR repo URI | `<ACCOUNT_ID>`.dkr.ecr.us-east-1.amazonaws.com/foundry-dev-app |
| ECS cluster name | foundry-dev-cluster |
| ECS service name | foundry-dev-app |
| ECS task definition family | foundry-dev-app |
| ECS task CPU / Memory | 256 / 512 (0.25 vCPU, 512 MiB) |
| ECS desired count | 2 (one per AZ) |
| Container port | 8080 |
| Container image | nginx:latest (custom config for port 8080) |
| ALB name | foundry-dev-alb |
| ALB DNS name | foundry-dev-alb-1683080614.us-east-1.elb.amazonaws.com |
| ALB security group | sg-01efcdea06926db65 |
| Target group name | foundry-dev-app-tg |
| Target group ARN | arn:aws:elasticloadbalancing:us-east-1:`<ACCOUNT_ID>`:targetgroup/foundry-dev-app-tg/`<TG_ID>` |
| ACM certificate ARN | arn:aws:acm:us-east-1:`<ACCOUNT_ID>`:certificate/`<CERT_ID>` |
| Route 53 hosted zone ID | Captured from `terraform output route53_zone_id` after first apply. Locked by `prevent_destroy`. |
| Route 53 nameservers | Captured from `terraform output route53_name_servers` after first apply. Authoritative — `prevent_destroy` on the zone keeps these stable across teardown cycles. |
| Domain name | icecreamtofightwith.com |
| Domain registrar | Squarespace (nameservers delegated to Route 53). Transfer to Route 53 Domains planned — see [issue #48](https://github.com/lentago/foundry-platform-demo/issues/48) and `docs/REGISTRAR_TRANSFER.md`. |
| CloudWatch log group | /ecs/foundry-dev-app |
| ECS auto-scaling | Not yet configured (Phase 3d) |

---

## Data Layer (Phase 4)

| Item | Value |
|------|-------|
| RDS instance identifier | foundry-dev-postgres |
| RDS endpoint | foundry-dev-postgres.c458aku0mtw1.us-east-1.rds.amazonaws.com:5432 |
| RDS address (hostname only) | foundry-dev-postgres.c458aku0mtw1.us-east-1.rds.amazonaws.com |
| RDS port | 5432 |
| RDS engine | PostgreSQL 16 (db.t4g.micro Graviton) |
| RDS storage | 20 GiB gp3, autoscale to 100 GiB |
| RDS Multi-AZ | Yes (synchronous standby) |
| RDS database name | awslab |
| RDS master username | dbadmin |
| RDS master secret ARN | arn:aws:secretsmanager:us-east-1:`<ACCOUNT_ID>`:secret:rds!db-`<SECRET_SUFFIX>` |
| RDS master secret rotation | Automatic, every 7 days (RDS-managed) |
| RDS security group | sg-0e62923842c97d48b |
| DB subnet group | foundry-dev-db-subnet-group |
| Parameter group | foundry-dev-pg16 |
| Performance Insights | Enabled (7-day retention, KMS encrypted) |
| Backup retention | 7 days |
| Backup window | 03:00–04:00 UTC |
| Maintenance window | Sun 05:00–06:00 UTC |
| S3 bucket name | TBD (Phase 4b) |
| ElastiCache cluster ID | TBD (Phase 4c) |
| ElastiCache endpoint | TBD (Phase 4c) |

---

## Observability (Phase 5)

| Item | Value |
|------|-------|
| SNS topic name | foundry-dev-alerts |
| SNS topic ARN | arn:aws:sns:us-east-1:`<ACCOUNT_ID>`:foundry-dev-alerts |
| Notification email | cpitzi@gmail.com |
| Email subscription confirmed | Yes (2026-03-19) |
| CloudWatch alarms (8 total) | ecs-cpu-high, ecs-memory-high, alb-5xx-high, alb-response-slow, rds-cpu-high, rds-storage-low, cache-cpu-high, cache-memory-high |
| Alarm naming pattern | foundry-dev-{service}-{metric} |
| CloudTrail trail name | foundry-dev-trail |
| CloudTrail S3 prefix | cloudtrail |
| CloudTrail S3 path | s3://foundry-dev-`<ACCOUNT_ID>`/cloudtrail/AWSLogs/`<ACCOUNT_ID>`/ |
| CloudTrail multi-region | Yes |
| CloudTrail log file validation | Yes |
| CloudTrail encryption | KMS (CMK) |
| AWS Config recorder | _TBD (Phase 5d)_ |

---

## CI/CD (Phase 6)

| Item | Value |
|------|-------|
| Deploy workflow file | `.github/workflows/deploy.yml` |
| Terraform workflow file | `.github/workflows/terraform.yml` |
| OIDC provider configured | ☐ |
| Branch protection enabled | ☐ |

---

## Decisions Log

_Quick-reference for architectural decisions made along the way. Full ADRs live in `docs/decisions/` in the repo._

| # | Decision | Rationale | Date |
|---|----------|-----------|------|
| 1 | AdministratorAccess on cpitzi-iac | Lab/sandbox account, sole user. Scoped permissions would create constant friction. Will scope down for CI/CD roles. | 2026-02-27 |
| 2 | AES256 encryption on state bucket (not KMS yet) | Avoids KMS dependency before Phase 2. Will upgrade to CMK later. | 2026-02-27 |
| 3 | 2 NAT Gateways (one per AZ) | Production-correct HA pattern. Accepted ~$65/mo cost over single-NAT savings. | 2026-02-27 |
| 4 | count over for_each for VPC subnets | Simpler to learn; fine for lab. Can refactor to for_each later for better state handling. | 2026-02-27 |
| 5 | Single KMS CMK for all encryption | $1/mo per key; lab doesn't need per-service key isolation. Key policy grants scoped to specific roles. | 2026-02-28 |
| 6 | Separate ECS task execution vs task role | Execution role = ECS control plane (image pull, logs, secrets injection). Task role = application runtime AWS access. Least-privilege separation. | 2026-02-28 |
| 7 | GitHub OIDC over IAM access keys | No long-lived credentials. Trust scoped to repo:lentago/foundry-platform-demo:*. | 2026-02-28 |
| 8 | Security groups as standalone module | Separation of concerns: VPC = network plumbing, SGs = access policy. Cleaner output wiring to consuming modules in Phases 3-4. | 2026-02-28 |
| 9 | Newer per-rule SG resources over legacy inline/aws_security_group_rule | aws_vpc_security_group_ingress_rule is the recommended path forward; older resources in maintenance mode. | 2026-02-28 |
| 10 | Hybrid module structure for Phase 2 (kms/, secrets/, iam/, security-groups/) | KMS + Secrets Manager tightly coupled but separate from IAM roles and security groups. Each module has a clear contract and output surface. | 2026-02-28 |
| 11 | Mutable image tags in ECR for dev | Allows pushing to `latest` repeatedly without errors. Would use IMMUTABLE in production to prevent overwriting deployed tags. | 2026-02-28 |
| 12 | DNS + ACM in single module | ACM DNS validation creates records in Route 53; tightly coupled. Separating them creates circular dependency headaches. | 2026-02-28 |
| 13 | Boolean `create_alb_alias` over conditional count on ALB DNS name | Terraform `count` can't depend on values unknown at plan time. Explicit boolean is known at plan time, avoids the "known after apply" error. | 2026-02-28 |
| 14 | TLS 1.2+ minimum (ELBSecurityPolicy-TLS13-1-2-2021-06) | AWS recommended policy. TLS 1.0/1.1 have known vulnerabilities. Only downside is dropping very old clients, acceptable for lab. | 2026-02-28 |
| 15 | ECS lifecycle ignore_changes for task_definition and desired_count | CI/CD updates task definitions, auto-scaling changes desired count. Without ignore_changes, terraform apply would revert these external changes. | 2026-02-28 |
| 16 | Custom nginx image for port 8080 | Stock nginx listens on 80; security groups and ALB target group expect 8080. Custom Dockerfile + nginx.conf aligns the port contract across all modules. | 2026-02-28 |
| 17 | Fargate target_type = "ip" | Required for Fargate. Each task gets its own ENI with a private IP; ALB routes directly to task IPs rather than EC2 instance IDs. | 2026-02-28 |
| 18 | icecreamtofightwith.com full domain delegation to Route 53 | Simpler than subdomain delegation. NS records updated at Squarespace to point to Route 53. | 2026-02-28 |
| 19 | RDS-managed master password over traditional Secrets Manager | Auto-rotation every 7 days, no password in Terraform state. Existing Phase 2 secret (foundry-dev/db-credentials) retained but unused by RDS. | 2026-03-19 |
| 20 | db.t4g.micro (Graviton) over db.t3.micro | Same price tier, ~20% better price-performance on ARM. Signals awareness of Graviton ecosystem. | 2026-03-19 |
| 21 | PostgreSQL 16 major-only version pin | Lets AWS pick latest minor version. Avoids breakage when AWS retires specific minor versions. | 2026-03-19 |
| 22 | gp3 storage over gp2 | Baseline 3,000 IOPS + 125 MiB/s included free. gp2 at 20 GiB would only get ~100 IOPS. | 2026-03-19 |
| 23 | IAM rds!* prefix pattern for secret access | Avoids circular dependency (RDS → IAM → RDS). Only RDS-managed secrets use the rds! prefix, so still least-privilege. | 2026-03-19 |
| 24 | SNS consolidated into monitoring module (not separate) | SNS topic exists solely for alarm delivery in this project. No other consumers justify a standalone module. Reduces wiring in main.tf. | 2026-03-19 |
| 25 | treat_missing_data = "notBreaching" on ALB alarms | ALB metrics like 5xx counts emit no data points when there are zero errors (rather than emitting "0"). Missing data should not trigger an alarm. | 2026-03-19 |
| 26 | EngineCPUUtilization over CPUUtilization for ElastiCache | Valkey/Redis is single-threaded. Host CPU can be misleadingly low on multi-vCPU nodes while the engine thread is saturated. EngineCPUUtilization isolates the engine's thread. | 2026-03-19 |
| 27 | ok_actions on all alarms (not just alarm_actions) | Sends recovery notifications so you know when an issue resolves itself, not just when it starts. Complete operational picture. | 2026-03-19 |
| 28 | 3 evaluation periods for most alarms | Avoids false positives from brief spikes. Three consecutive breaching periods confirms a real trend before alerting. | 2026-03-19 |
| 29 | Direct KMS encryption on CloudTrail (kms_key_id) over S3-only encryption | Defense-in-depth: logs are encrypted by CloudTrail before S3 delivery, not just at rest. Stronger portfolio signal; demonstrates KMS service principal integration. | 2026-03-19 |
| 30 | is_multi_region_trail = true | IAM and other global services emit events in us-east-1 regardless of deployment region. Multi-region ensures complete audit coverage. | 2026-03-19 |
| 31 | enable_log_file_validation = true | Creates hourly digest files with SHA-256 hashes for tamper detection. Required by most compliance frameworks (SOC 2, PCI DSS, HIPAA). | 2026-03-19 |
| 32 | Management events only (no data events) | Data events (S3 object ops, Lambda invocations) would generate massive volume and cost for a lab. Management events cover the resource-level audit questions. | 2026-03-19 |
| 33 | S3 bucket policy owned by CloudTrail module (not S3 module) | Keeps the S3 module general-purpose. The consumer (CloudTrail) manages its own access. If AWS Config also needs bucket access, we'll consolidate into a shared policy. | 2026-03-19 |
| 34 | EncryptionContext condition (not aws:SourceArn) on KMS key policy | Avoids circular dependency: trail needs key ARN, and SourceArn condition would need trail ARN. EncryptionContext scoped to account is sufficient for single-account use. | 2026-03-19 |

---

## Cost Tracking

| Date | Monthly Run Rate | Notes |
|------|-----------------|-------|
| 2026-02-27 | ~$65/mo | Phase 1 only: 2 NAT Gateways + 2 EIPs. `terraform destroy` when idle. |
| 2026-02-28 | ~$66/mo | Phase 2 adds: KMS key ($1/mo), Secrets Manager ($0.40/mo). IAM and SGs are free. |
| 2026-02-28 | ~$112/mo | Phase 3 adds: ALB (~$20/mo), Route 53 hosted zone ($0.50/mo), ECS Fargate 2x 0.25vCPU/512MiB (~$25/mo). ACM certs are free. ECR storage negligible. |
| 2026-03-19 | ~$143/mo | Phase 4a adds: RDS db.t4g.micro Multi-AZ (~$28/mo), gp3 storage (~$2.30/mo), backups + managed secret (~$0.80/mo). |
| 2026-03-19 | ~$144/mo | Phase 5a+5b adds: 8 CloudWatch alarms (~$0.80/mo). SNS email delivery free. |
| 2026-03-19 | ~$144/mo | Phase 5c adds: CloudTrail (first trail free for management events). S3 storage negligible. |

---

## Progress Tracker

| Phase | Status | Started | Completed |
|-------|--------|---------|-----------|
| 0 — Foundation & Tooling | Complete | 2026-02-27 | 2026-02-27 |
| 1 — Networking | Complete | 2026-02-27 | 2026-02-27 |
| 2 — Security | Complete | 2026-02-28 | 2026-02-28 |
| 3 — Compute & Containers | Complete | 2026-02-28 | 2026-02-28 |
| 4 — Data Layer | Complete | 2026-03-19 | 2026-03-19 |
| 5 — Observability | In Progress | 2026-03-19 | |
| 6 — CI/CD | Not Started | | |
| 7 — Hardening | Not Started | | |

---

## Terraform Module Structure

```
modules/
├── vpc/              # Phase 1: VPC, subnets, IGW, NAT, route tables, flow logs
├── kms/              # Phase 2: Customer-managed encryption key
├── secrets/          # Phase 2: Secrets Manager (db credentials pattern)
├── iam/              # Phase 2: ECS roles, GitHub OIDC provider + role
├── security-groups/  # Phase 2: ALB → App → RDS/Redis security group chain
├── ecr/              # Phase 3: Container image registry with lifecycle policy
├── dns/              # Phase 3: Route 53 hosted zone, ACM cert, ALB alias record
├── alb/              # Phase 3: Application Load Balancer, listeners, target group
├── ecs/              # Phase 3: Fargate cluster, task definition, service
├── ecs-autoscaling/  # Phase 3: CPU + memory target-tracking scaling policies
├── rds/              # Phase 4: PostgreSQL Multi-AZ with RDS-managed credentials
├── s3/               # Phase 4: General-purpose bucket with KMS encryption
├── elasticache/      # Phase 4: Valkey replication group with encryption
├── monitoring/       # Phase 5: SNS topic + 8 CloudWatch alarms (ECS, ALB, RDS, ElastiCache)
└── cloudtrail/       # Phase 5: API audit trail with S3 delivery and KMS encryption
```

---


## Manual Bootstrap Steps (Non-IaC Prerequisites)

_These steps cannot be automated with Terraform and must be performed manually when setting up the environment from scratch._

| Step | When Needed | Command / Action | Idempotent? |
|------|-------------|-----------------|-------------|
| AWS account setup + MFA | Initial setup only | AWS Console | Yes |
| Install CLI tools (terraform, aws, docker, kubectl, git) | Initial setup only | Package managers | Yes |
| Bootstrap Terraform backend (S3 + DynamoDB) | Initial setup only | bootstrap script / AWS CLI | Yes |
| Add user to docker group | After OS reinstall | `sudo usermod -aG docker $USER` + restart terminal | Yes |
| Authenticate Docker to ECR | Every 12 hours | `aws ecr get-login-password ... \| docker login ...` | Yes |
| Build and push container image to ECR | After ECR repo creation or image changes | `docker build` + `docker push` | Yes |
| Update nameservers at Squarespace | Once, after first Route 53 hosted zone creation | Squarespace domain settings → custom NS | `prevent_destroy` on the zone keeps NSes stable. Eliminated entirely after registrar transfer (see `docs/REGISTRAR_TRANSFER.md`). |
| Restore Secrets Manager secret after destroy | Every `terraform apply` within 7 days of destroy | `aws secretsmanager restore-secret` + `terraform import` | Yes |
| Restore KMS key after destroy | Every `terraform apply` within 30 days of destroy | `aws kms cancel-key-deletion` + `aws kms enable-key` (+ import if needed) | Yes |
| Confirm SNS email subscription | After first `terraform apply` of monitoring module, or after destroy/recreate | Check cpitzi@gmail.com for AWS confirmation email, click link | Yes (re-subscribing sends a new confirmation) |


## Operations Notes

_Operational knowledge for day-to-day work with this environment._

| Topic | Detail |
|-------|--------|
| **Daily teardown** | `terraform destroy` when idle to save ~$2.15/day (NAT Gateways). `terraform apply` recreates everything identically from code. |
| **Secrets Manager recovery window** | Secret has `recovery_window_in_days = 7`. After `terraform destroy`, the secret name is reserved for 7 days. Next `terraform apply` restores the pending-deletion secret — this is normal. If you hit "already scheduled for deletion" errors, either wait out the window or temporarily set recovery window to `0` for immediate deletion. Only an issue because we're using placeholder values; would not do this with real credentials. |
| **KMS key deletion** | KMS key has `deletion_window_in_days = 30`. On destroy, Terraform schedules deletion (doesn't delete immediately). On next apply, it cancels the scheduled deletion and restores the key. No data loss, no new key ID needed. |
| **ECR authentication** | `aws ecr get-login-password --region us-east-1 --profile foundry \| docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text --profile foundry).dkr.ecr.us-east-1.amazonaws.com` — Token valid for 12 hours. Required before docker push/pull to ECR. |
| **Push image to ECR** | `docker build -t $(terraform output -raw ecr_repository_url):latest .` then `docker push ...`. Build from `app/` directory. |
| **Squarespace NS delegation** | One-time manual step (truly one-time now — the zone has `prevent_destroy`): In Squarespace domain settings, set custom nameservers to the 4 Route 53 NS values from `terraform output route53_name_servers`. Check propagation with `dig icecreamtofightwith.com NS +short`. Eliminated entirely after registrar transfer (`docs/REGISTRAR_TRANSFER.md`). |
| **ACM cert validation wait** | `terraform apply` will hang at `aws_acm_certificate_validation` until DNS propagation completes and ACM verifies the CNAME records. Can take 5-45 minutes. Safe to Ctrl+C and re-apply later. |
| **Docker group on ChromeOS** | User must be in `docker` group: `sudo usermod -aG docker $USER`. Requires terminal restart (or `newgrp docker`) to take effect. |
| **ECS task startup time** | After apply, tasks take ~60-90 seconds to pull image, start, and pass 3 consecutive health checks (30s interval). 503 from ALB is expected during this window. |
| **Route 53 hosted zone on destroy** | Zone has `lifecycle { prevent_destroy = true }` — `terraform destroy` will refuse to drop it, preserving NS delegation across teardown cycles. To genuinely remove the zone (e.g., tearing down the project), remove the lifecycle block, apply, then destroy. See issue #48 and `docs/REGISTRAR_TRANSFER.md` for the durable fix. |
| **SNS subscription on recreate** | After `terraform destroy` + `terraform apply`, the SNS email subscription is recreated in "pending confirmation" state. No alarms are delivered until you click the confirmation link in the new email from AWS. Check Gmail immediately after apply. |
| **Testing alarm pipeline** | `aws cloudwatch set-alarm-state --alarm-name "foundry-dev-ecs-cpu-high" --state-value ALARM --state-reason "Test" --profile foundry` — Forces alarm to ALARM state. Auto-recovers on next evaluation period. Useful for validating the SNS→email chain. |
| **INSUFFICIENT_DATA alarms** | Normal after fresh deploy. Alarms need 1–3 evaluation periods of metric data before transitioning to OK. RDS and ElastiCache alarms may take 5–15 minutes to settle. |
| **CloudTrail first delivery** | After `terraform apply`, CloudTrail takes 5–15 minutes to deliver the first log files to S3. Check with `aws s3 ls s3://$(terraform output -raw s3_bucket_id)/cloudtrail/ --recursive --profile foundry`. |
| **CloudTrail verification** | `aws cloudtrail get-trail-status --name foundry-dev-trail --profile foundry` — should show `IsLogging: true` and `LatestDeliveryTime` populated within ~15 minutes. |

---

## Troubleshooting Notes

_Things that bit us and how we fixed them._

| Issue | Resolution | Date |
|-------|-----------|------|
| DynamoDB CreateTable AccessDenied on cpitzi-iac | User only had S3 + EC2 policies. Attached AdministratorAccess via root console. | 2026-02-27 |
| Secrets Manager "already scheduled for deletion" on apply after destroy | Secret has 7-day recovery window. Restore with `aws secretsmanager restore-secret --secret-id <name> --profile foundry`, then `terraform import module.secrets.aws_secretsmanager_secret.db_credentials <name>` to sync state, then re-apply. | 2026-02-28 |
| KMS "pending deletion" causing Secrets Manager DecryptionFailure | Cascading dependency: secret encrypted with KMS key that's also pending deletion. Fix KMS first: `aws kms cancel-key-deletion --key-id <id> --profile foundry` then `aws kms enable-key --key-id <id> --profile foundry`. If KMS not in state, import it too. Then re-apply. | 2026-02-28 |
| Full resurrection sequence after `terraform destroy` with delayed-deletion resources | Order matters: (1) cancel KMS key deletion + enable, (2) restore Secrets Manager secret, (3) import any resources missing from state (`terraform import`), (4) `terraform apply`. The dependency chain runs in reverse on the way back up. | 2026-02-28 |
| Terraform "count depends on resource attributes that cannot be determined until apply" | Can't use `count` with a value that's `known after apply`. Replace with a boolean variable that's set to a literal value (`true`/`false`) in the module call. Boolean is known at plan time. | 2026-02-28 |
| Docker "permission denied" on /var/run/docker.sock | User not in docker group. `sudo usermod -aG docker $USER` then restart terminal or `newgrp docker`. | 2026-02-28 |
| 503 from ALB immediately after ECS deploy | Normal — tasks need ~90 seconds to pull image, start, and pass 3 health checks. Wait and retry. Check target health with `aws elbv2 describe-target-health`. | 2026-02-28 |

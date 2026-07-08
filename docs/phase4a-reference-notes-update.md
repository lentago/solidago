# Phase 4a Reference Notes Update

Add this to `docs/foundry-reference-notes.md` — replace the placeholder
Data Layer section.

---

## Data Layer (Phase 4)

| Item | Value |
|------|-------|
| RDS instance identifier | solidago-dev-postgres |
| RDS endpoint | solidago-dev-postgres.c458aku0mtw1.us-east-1.rds.amazonaws.com:5432 |
| RDS address (hostname only) | solidago-dev-postgres.c458aku0mtw1.us-east-1.rds.amazonaws.com |
| RDS port | 5432 |
| RDS engine | PostgreSQL 16 (db.t4g.micro Graviton) |
| RDS storage | 20 GiB gp3, autoscale to 100 GiB |
| RDS Multi-AZ | Yes (synchronous standby) |
| RDS database name | awslab |
| RDS master username | dbadmin |
| RDS master secret ARN | arn:aws:secretsmanager:us-east-1:`<ACCOUNT_ID>`:secret:rds!db-`<SECRET_SUFFIX>` |
| RDS master secret rotation | Automatic, every 7 days (RDS-managed) |
| RDS security group | sg-0e62923842c97d48b |
| DB subnet group | solidago-dev-db-subnet-group |
| Parameter group | solidago-dev-pg16 |
| Performance Insights | Enabled (7-day retention, KMS encrypted) |
| Backup retention | 7 days |
| Backup window | 03:00–04:00 UTC |
| Maintenance window | Sun 05:00–06:00 UTC |
| S3 bucket name | _TBD (Phase 4b)_ |
| ElastiCache cluster ID | _TBD (Phase 4c)_ |
| ElastiCache endpoint | _TBD (Phase 4c)_ |

---

Also update the **Decisions Log** table — add:

| # | Decision | Rationale | Date |
|---|----------|-----------|------|
| 19 | RDS-managed master password over traditional Secrets Manager | Auto-rotation every 7 days, no password in Terraform state. Existing Phase 2 secret (solidago-dev/db-credentials) retained but unused by RDS. | 2026-03-19 |
| 20 | db.t4g.micro (Graviton) over db.t3.micro | Same price tier, ~20% better price-performance on ARM. Signals awareness of Graviton ecosystem. | 2026-03-19 |
| 21 | PostgreSQL 16 major-only version pin | Lets AWS pick latest minor version. Avoids breakage when AWS retires specific minor versions. | 2026-03-19 |
| 22 | gp3 storage over gp2 | Baseline 3,000 IOPS + 125 MiB/s included free. gp2 at 20 GiB would only get ~100 IOPS. | 2026-03-19 |
| 23 | IAM rds!* prefix pattern for secret access | Avoids circular dependency (RDS → IAM → RDS). Only RDS-managed secrets use the rds! prefix, so still least-privilege. | 2026-03-19 |

---

Also update the **Cost Tracking** table — add:

| Date | Monthly Run Rate | Notes |
|------|-----------------|-------|
| 2026-03-19 | ~$143/mo | Phase 4a adds: RDS db.t4g.micro Multi-AZ (~$28/mo), gp3 storage (~$2.30/mo), backups + managed secret (~$0.80/mo). |

---

Also update the **Progress Tracker**:

| Phase | Status | Started | Completed |
|-------|--------|---------|-----------|
| 3 — Compute & Containers | Complete | 2026-02-28 | 2026-02-28 |
| 4 — Data Layer | In Progress | 2026-03-19 | |

# modules/elasticache/main.tf
# -------------------------------------------------------------------
# ElastiCache Valkey (Redis-compatible) with encryption and monitoring.
#
# Key architecture decisions:
#   - Valkey over Redis: API-compatible, 20% cheaper, AWS-backed fork
#     after Redis licensing change in 2024.
#   - Replication group (not standalone cluster): even with 1 node,
#     aws_elasticache_replication_group is the correct resource. It
#     supports promotion to multi-node later without replacement.
#   - Transit encryption: TLS required for all connections. Clients
#     must use TLS-capable libraries (all modern Redis clients do).
#   - Single node here: keeps costs at ~$12/mo. Add a second node
#     to enable automatic failover for production.
# -------------------------------------------------------------------

# --- Subnet Group ---
# Same concept as RDS DB subnet groups — tells ElastiCache which
# subnets it can place nodes in.
resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-valkey"
  subnet_ids = var.data_subnet_ids

  tags = {
    Name = "${var.project}-${var.environment}-valkey-subnet-group"
  }
}

# --- Parameter Group ---
# Valkey/Redis configuration knobs. Custom group allows tuning
# without replacing the cluster (the default group is immutable).
resource "aws_elasticache_parameter_group" "this" {
  name   = "${var.project}-${var.environment}-valkey7"
  family = var.parameter_group_family

  # maxmemory-policy controls what happens when the cache is full.
  # allkeys-lru evicts the least-recently-used keys across ALL keys.
  # This is the safest general-purpose policy — it prevents OOM errors
  # by automatically making room for new data.
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  # Track latency statistics — useful for Performance diagnostics
  parameter {
    name  = "latency-tracking"
    value = "yes"
  }

  tags = {
    Name = "${var.project}-${var.environment}-valkey7-params"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Replication Group ---
# The main cache resource. Even for a single node, we use a
# replication_group (not aws_elasticache_cluster) because:
#   1. It's the recommended resource for Valkey/Redis
#   2. It supports seamless promotion to multi-node
#   3. It supports transit encryption (standalone clusters don't)
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.project}-${var.environment}-valkey"
  description          = "Valkey cache for ${var.project}-${var.environment}"

  # Engine
  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = var.port

  # Topology — single node for this environment
  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  # Networking
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.redis_security_group_id]

  # Encryption at rest — Valkey defaults to true, but we explicitly
  # set it and provide our KMS key for consistency with RDS and S3.
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn

  # Encryption in transit — requires TLS connections from clients.
  # All modern Redis/Valkey client libraries support this natively.
  transit_encryption_enabled = true

  # Configuration
  parameter_group_name = aws_elasticache_parameter_group.this.name

  # Maintenance
  maintenance_window         = var.maintenance_window
  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  # Snapshots (backups)
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_window

  tags = {
    Name = "${var.project}-${var.environment}-valkey"
  }
}

# Amazon ElastiCache for Valkey — replaces the Redis container embedded in
# the upstream docling-rq chart (design decision: OSS-based managed service,
# drop-in via `redis.enabled=false` + external redisUrl secret using a
# rediss:// URL; RQ/redis-py support TLS + AUTH out of the box).

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "this" {
  name        = "${var.name}-valkey"
  description = "Valkey access from EKS"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

# Keyed by static map keys so for_each works with apply-time unknown SG IDs.
resource "aws_vpc_security_group_ingress_rule" "valkey" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Valkey from EKS (${each.key})"
}

resource "aws_elasticache_replication_group" "this" {
  # One node is enough for an RQ broker whose queue content is rebuilt by
  # the workers; a replica + automatic failover doubles the cache cost for a
  # demo without an availability requirement.
  #checkov:skip=CKV2_AWS_50: Single-node demo broker; a failover replica adds cost without a demo benefit
  replication_group_id = var.name
  description          = "SPARK Workflow docling-rq broker (Valkey)"

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type

  num_cache_clusters = 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  transit_encryption_enabled = true
  auth_token                 = var.auth_token
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn

  automatic_failover_enabled = false
  snapshot_retention_limit   = 0
  apply_immediately          = true

  tags = var.tags
}

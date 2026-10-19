output "primary_endpoint" {
  description = "Primary endpoint address of the Valkey replication group."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  description = "Valkey port."
  value       = 6379
}

output "redis_url" {
  description = "rediss:// connection URL incl. AUTH token (for the docling-rq redisUrl secret)."
  value       = "rediss://:${var.auth_token}@${aws_elasticache_replication_group.this.primary_endpoint_address}:6379/0"
  sensitive   = true
}

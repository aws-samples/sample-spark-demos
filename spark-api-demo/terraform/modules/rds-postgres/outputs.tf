output "endpoint" {
  description = "RDS endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "host" {
  description = "RDS host name."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port."
  value       = aws_db_instance.this.port
}

output "master_username" {
  description = "Master user name."
  value       = aws_db_instance.this.username
}

output "security_group_id" {
  description = "Security group protecting the DB instance."
  value       = aws_security_group.this.id
}

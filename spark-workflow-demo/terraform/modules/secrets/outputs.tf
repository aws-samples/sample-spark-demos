output "rds_master_password" {
  description = "Generated RDS master password (consumed by the rds-postgres module)."
  value       = random_password.rds_master.result
  sensitive   = true
}

output "valkey_auth_token" {
  description = "Generated Valkey AUTH token (consumed by the elasticache-valkey module)."
  value       = random_password.valkey_auth_token.result
  sensitive   = true
}

output "secret_arns" {
  description = "ARNs of all Secrets Manager entries (scoping for the ESO pod identity policy)."
  value = concat(
    [
      aws_secretsmanager_secret.rds_master.arn,
      aws_secretsmanager_secret.s3_app.arn,
      aws_secretsmanager_secret.keycloak.arn,
      aws_secretsmanager_secret.oauth2_proxy.arn,
      aws_secretsmanager_secret.spicedb.arn,
      aws_secretsmanager_secret.litellm.arn,
      aws_secretsmanager_secret.fpp.arn,
    ],
    [for s in aws_secretsmanager_secret.db_user : s.arn],
    [for s in aws_secretsmanager_secret.valkey : s.arn],
  )
}

output "secret_names" {
  description = "Logical map of Secrets Manager secret names (referenced by ExternalSecret resources)."
  value = merge(
    {
      rds_master   = aws_secretsmanager_secret.rds_master.name
      s3_app       = aws_secretsmanager_secret.s3_app.name
      keycloak     = aws_secretsmanager_secret.keycloak.name
      oauth2_proxy = aws_secretsmanager_secret.oauth2_proxy.name
      spicedb      = aws_secretsmanager_secret.spicedb.name
      litellm      = aws_secretsmanager_secret.litellm.name
      fpp          = aws_secretsmanager_secret.fpp.name
    },
    { for k, s in aws_secretsmanager_secret.db_user : "rds_${k}" => s.name },
    length(aws_secretsmanager_secret.valkey) > 0 ? { valkey = aws_secretsmanager_secret.valkey[0].name } : {},
  )
}

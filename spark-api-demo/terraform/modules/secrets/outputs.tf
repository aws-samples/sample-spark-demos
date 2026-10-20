output "rds_master_password" {
  description = "Generated RDS master password (consumed by the rds-postgres module)."
  value       = random_password.rds_master.result
  sensitive   = true
}

output "secret_arns" {
  description = "ARNs of all Secrets Manager entries (scoping for the ESO pod identity policy)."
  value = concat(
    [
      aws_secretsmanager_secret.rds_master.arn,
      aws_secretsmanager_secret.rds_app.arn,
      aws_secretsmanager_secret.rabbitmq.arn,
      aws_secretsmanager_secret.neo4j.arn,
      aws_secretsmanager_secret.litellm.arn,
      aws_secretsmanager_secret.bizlog.arn,
      aws_secretsmanager_secret.keycloak.arn,
      aws_secretsmanager_secret.oauth2_proxy.arn,
      aws_secretsmanager_secret.s3_app.arn,
    ],
    [for s in aws_secretsmanager_secret.external_oidc : s.arn],
  )
}

output "secret_names" {
  description = "Logical map of Secrets Manager secret names (referenced by ExternalSecret resources)."
  value = merge(
    {
      rds_master   = aws_secretsmanager_secret.rds_master.name
      rds_app      = aws_secretsmanager_secret.rds_app.name
      rabbitmq     = aws_secretsmanager_secret.rabbitmq.name
      neo4j        = aws_secretsmanager_secret.neo4j.name
      litellm      = aws_secretsmanager_secret.litellm.name
      bizlog       = aws_secretsmanager_secret.bizlog.name
      keycloak     = aws_secretsmanager_secret.keycloak.name
      oauth2_proxy = aws_secretsmanager_secret.oauth2_proxy.name
      s3_app       = aws_secretsmanager_secret.s3_app.name
    },
    length(aws_secretsmanager_secret.external_oidc) > 0 ? { external_oidc = aws_secretsmanager_secret.external_oidc[0].name } : {},
  )
}

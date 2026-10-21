output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Command to configure kubectl."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "frontend_url" {
  description = "SPARK Workflow frontend URL."
  value       = "https://${local.frontend_fqdn}/app/"
}

output "keycloak_url" {
  description = "Keycloak URL."
  value       = "https://${local.keycloak_fqdn}"
}

output "temporal_ui_url" {
  description = "Temporal UI URL."
  value       = "https://${local.temporal_fqdn}"
}

output "rds_endpoint" {
  description = "RDS endpoint."
  value       = module.rds.endpoint
}

output "s3_buckets" {
  description = "S3 bucket names."
  value       = module.s3.bucket_names
}

output "valkey_endpoint" {
  description = "Valkey primary endpoint (docling-rq broker)."
  value       = module.valkey.primary_endpoint
}

output "secret_names" {
  description = "Secrets Manager entries (input for ExternalSecret resources)."
  value       = module.secrets.secret_names
}

output "demo_credentials_hint" {
  description = "Where to find the demo login credentials."
  value       = "aws secretsmanager get-secret-value --secret-id ${module.secrets.secret_names["keycloak"]} --query SecretString --output text | jq ."
}

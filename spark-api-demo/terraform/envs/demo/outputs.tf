output "cluster_name" {
  description = "EKS cluster name (for aws eks update-kubeconfig)."
  value       = module.eks.cluster_name
}

output "api_url" {
  description = "Public base URL of the SPARK API demo."
  value       = "https://${local.api_fqdn}"
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint."
  value       = module.rds.host
}

output "bucket_names" {
  description = "S3 bucket names."
  value       = module.s3.bucket_names
}

output "secret_names" {
  description = "Secrets Manager entries created for the demo."
  value       = module.secrets.secret_names
}

output "source_bucket" {
  description = "S3 bucket for the source zip (push target of scripts/push-source.sh)."
  value       = module.registry_build.source_bucket
}

output "codebuild_project" {
  description = "CodeBuild project that builds all images."
  value       = module.registry_build.codebuild_project
}

output "ecr_registry" {
  description = "ECR registry host for the built images."
  value       = module.registry_build.ecr_registry
}

output "auth_url" {
  description = "Public Keycloak base URL of the OIDC perimeter."
  value       = "https://${local.auth_fqdn}"
}

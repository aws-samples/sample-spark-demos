output "platform_namespace" {
  description = "Namespace for platform components."
  value       = kubernetes_namespace_v1.platform.metadata[0].name
}

output "app_namespace" {
  description = "Namespace for the SPARK Workflow application."
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "gateway_name" {
  description = "Name of the shared Gateway resource."
  value       = "spark-demo"
}

output "cluster_secret_store_name" {
  description = "Name of the ESO ClusterSecretStore."
  value       = "aws-secrets-manager"
}

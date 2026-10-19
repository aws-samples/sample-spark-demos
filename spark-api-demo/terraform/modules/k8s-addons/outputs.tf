output "platform_namespace" {
  description = "Namespace for platform components."
  value       = kubernetes_namespace_v1.platform.metadata[0].name
}

output "app_namespace" {
  description = "Namespace for the application umbrella."
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "cluster_secret_store" {
  description = "Name of the ESO ClusterSecretStore."
  value       = "aws-secrets-manager"
}

output "cluster_issuer" {
  description = "Name of the cert-manager ClusterIssuer."
  value       = "letsencrypt"
}

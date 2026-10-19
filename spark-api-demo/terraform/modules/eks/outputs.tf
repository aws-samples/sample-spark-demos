output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Cluster primary security group ID."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID shared by all managed node groups."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (for IRSA fallbacks)."
  value       = module.eks.oidc_provider_arn
}

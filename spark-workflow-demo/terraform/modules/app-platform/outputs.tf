output "release_name" {
  description = "Helm release name of the platform layer."
  value       = helm_release.platform.name
}

output "release_status" {
  description = "Status of the platform release."
  value       = helm_release.platform.status
}

output "demo_user_id" {
  description = "Keycloak id of the demo user (the backend's SYSTEM_USER_ID)."
  value       = var.demo_user_id
}

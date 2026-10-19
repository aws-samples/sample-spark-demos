output "release_name" {
  description = "Helm release name of the application umbrella."
  value       = helm_release.spark_workflow.name
}

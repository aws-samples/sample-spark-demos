output "source_bucket" {
  description = "Versioned S3 bucket the push script uploads the source zip to."
  value       = aws_s3_bucket.source.bucket
}

output "source_object_key" {
  description = "Expected object key of the source zip."
  value       = var.source_object_key
}

output "codebuild_project" {
  description = "CodeBuild project name (start-build-batch target)."
  value       = aws_codebuild_project.images.name
}

output "ecr_registry" {
  description = "ECR registry host."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "ecr_repositories" {
  description = "Map of image name to ECR repository URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

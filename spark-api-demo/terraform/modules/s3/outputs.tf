output "bucket_names" {
  description = "Map of logical key to bucket name."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "s3_endpoint_url" {
  description = "Regional S3 endpoint URL for the application configuration."
  value       = "https://s3.${data.aws_region.current.name}.amazonaws.com"
}

output "app_access_key_id" {
  description = "Access key ID of the application IAM user."
  value       = aws_iam_access_key.app.id
  sensitive   = true
}

output "app_secret_access_key" {
  description = "Secret access key of the application IAM user."
  value       = aws_iam_access_key.app.secret
  sensitive   = true
}

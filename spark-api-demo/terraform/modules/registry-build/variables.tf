variable "name" {
  description = "Name prefix (also the ECR repo namespace)."
  type        = string
}

variable "services_file" {
  description = "Path to pipeline/services.txt (single source of truth for images)."
  type        = string
}

variable "source_object_key" {
  description = "Object key of the source zip in the source bucket."
  type        = string
  default     = "source/spark-api-source.zip"
}

variable "compute_type" {
  description = "CodeBuild compute type for image builds."
  type        = string
  default     = "BUILD_GENERAL1_MEDIUM"
}

variable "build_timeout_minutes" {
  description = "Timeout of a single image build."
  type        = number
  default     = 60
}

variable "batch_timeout_minutes" {
  description = "Timeout of the whole build batch."
  type        = number
  default     = 240
}

variable "ecr_keep_images" {
  description = "Number of images retained per ECR repository."
  type        = number
  default     = 5
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the source bucket, the ECR repositories, the CodeBuild project and its log group (kms module)."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the CodeBuild log group in days."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "frontend_compute_type" {
  description = "CodeBuild compute type for the frontend monorepo build. The Dockerfile runs 16 vite builds in parallel: MEDIUM (7 GB) OOMed always, LARGE (15 GB) OOMed nondeterministically once the shell build stopped failing early (observed: 'Killed' at 183s, a random MFE loses its dist). XLARGE (70 GB) gives deterministic headroom."
  type        = string
  default     = "BUILD_GENERAL1_XLARGE"
}

variable "name" {
  description = "Prefix for bucket names (account ID is appended for global uniqueness)."
  type        = string
}

variable "frontend_origin" {
  description = "Browser origin of the demo frontend (CORS for presigned URLs), e.g. https://workflow.demo.example.com"
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for SSE-KMS default encryption (kms module)."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent object versions expire (versioning is enabled on every bucket)."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

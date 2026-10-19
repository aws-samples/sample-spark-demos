variable "name" {
  description = "Name prefix for buckets and the IAM user."
  type        = string
}

variable "buckets" {
  description = "Logical bucket map: key => { cors = whether the browser reaches this bucket via presigned URLs (needs the frontend-origin CORS rule) }."
  type = map(object({
    cors = optional(bool, false)
  }))
  default = {
    documents = { cors = true }
  }
}

variable "frontend_origin" {
  description = "Public frontend origin allowed by the CORS rules (https://host)."
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

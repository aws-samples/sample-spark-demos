variable "name" {
  description = "Prefix for Secrets Manager secret names."
  type        = string
}

variable "rds_host" {
  description = "RDS host name (embedded into connection secrets)."
  type        = string
}

variable "rds_port" {
  description = "RDS port."
  type        = number
  default     = 5432
}

variable "rds_master_username" {
  description = "RDS master user name."
  type        = string
  default     = "postgres"
}

variable "s3_endpoint_url" {
  description = "Regional S3 endpoint URL."
  type        = string
}

variable "s3_region" {
  description = "Region of the S3 buckets."
  type        = string
}

variable "s3_bucket_names" {
  description = "Logical key => bucket name map (stored as bucket_<key> in the s3 app secret)."
  type        = map(string)
}

variable "s3_access_key_id" {
  description = "Access key ID of the application IAM user."
  type        = string
  sensitive   = true
}

variable "s3_secret_access_key" {
  description = "Secret access key of the application IAM user."
  type        = string
  sensitive   = true
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key that encrypts every secret (kms module)."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "platform_namespace" {
  description = "Namespace of the in-cluster platform services (embedded into the RabbitMQ URL)."
  type        = string
  default     = "spark-api-platform"
}

variable "auth_host" {
  description = "Public Keycloak hostname (embedded into the token URL of the keycloak secret)."
  type        = string
}

variable "external_oidc_issuer_url" {
  description = "Issuer URL of an optional corporate OIDC provider placed in front of the perimeter (empty = disabled)."
  type        = string
  default     = ""
}

variable "external_oidc_client_id" {
  description = "Client ID registered at the external OIDC provider."
  type        = string
  default     = ""
}

variable "external_oidc_client_secret" {
  description = "Client secret issued by the external OIDC provider."
  type        = string
  default     = ""
  sensitive   = true
}

variable "keycloak_realm" {
  description = "Keycloak realm for the demo perimeter."
  type        = string
  default     = "local"
}

variable "keycloak_client_id" {
  description = "Confidential OIDC client used by oauth2-proxy."
  type        = string
  default     = "spark-api-demo"
}

variable "keycloak_demo_user_email" {
  description = "Login of the seeded demo user."
  type        = string
  default     = "demo.user@example.com"
}

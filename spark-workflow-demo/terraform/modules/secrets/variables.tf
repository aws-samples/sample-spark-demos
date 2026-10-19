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
  description = "Map with keys dms, temporal_payloads, quarantine."
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

variable "valkey_url" {
  description = "rediss:// URL of the ElastiCache Valkey broker (null when Valkey is disabled)."
  type        = string
  default     = null
  sensitive   = true
}

variable "keycloak_demo_user_email" {
  description = "E-mail of the demo login user provisioned in Keycloak."
  type        = string
}

variable "keycloak_host" {
  description = "Public Keycloak FQDN (used for the OIDC token URL stored alongside the client credentials)."
  type        = string
}

variable "keycloak_realm" {
  description = "Keycloak realm name."
  type        = string
  default     = "local"
}

variable "keycloak_client_id" {
  description = "OIDC client ID."
  type        = string
  default     = "local-client"
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

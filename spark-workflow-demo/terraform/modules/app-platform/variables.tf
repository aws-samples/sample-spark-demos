variable "chart_path" {
  description = "Local path to the spark-platform Helm chart."
  type        = string
}

variable "platform_namespace" {
  description = "Namespace of the platform components (created by k8s-addons)."
  type        = string
  default     = "spark-platform"
}

variable "app_namespace" {
  description = "Namespace of the application umbrella."
  type        = string
  default     = "spark"
}

variable "cluster_secret_store" {
  description = "Name of the ESO ClusterSecretStore."
  type        = string
}

variable "secret_names" {
  description = "Map of Secrets Manager entry names (output of the secrets module)."
  type        = map(string)
}

variable "external_oidc_issuer_url" {
  description = "Issuer URL of an optional corporate OIDC provider brokered by the demo Keycloak realm (empty = disabled)."
  type        = string
  default     = ""
}

variable "hosts" {
  description = "FQDNs: frontend, keycloak, temporal."
  type = object({
    frontend = string
    keycloak = string
    temporal = string
  })
}

variable "rds_host" {
  description = "RDS host."
  type        = string
}

variable "rds_port" {
  description = "RDS port."
  type        = number
  default     = 5432
}

variable "s3_endpoint_url" {
  description = "Regional S3 endpoint."
  type        = string
}

variable "s3_region" {
  description = "S3/AWS region."
  type        = string
}

variable "s3_dms_bucket" {
  description = "Name of the dms bucket (seed upload + app storage)."
  type        = string
}

variable "seed_file_path" {
  description = "Local path to the upstream gesetze-normen seed (from the submodule)."
  type        = string
}

variable "bedrock_region" {
  description = "Bedrock invocation region."
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model ID served as the chat model."
  type        = string
  default     = "openai.gpt-oss-120b-1:0"
}

variable "bedrock_vlm_model_id" {
  description = "Bedrock model/inference-profile ID served as the vision (VLM) model."
  type        = string
}

variable "vlm_model_name" {
  description = "App-facing model name LiteLLM exposes for the VLM (self-hosted/* prefix)."
  type        = string
}


variable "demo_user_id" {
  description = "Keycloak id of the demo user created by the bootstrap job; the backend pools record it as SYSTEM_USER_ID."
  type        = string
  default     = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}

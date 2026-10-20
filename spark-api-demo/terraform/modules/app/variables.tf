variable "platform_chart_path" {
  description = "Path to the local platform chart."
  type        = string
}

variable "umbrella_chart_path" {
  description = "Path to the local umbrella chart."
  type        = string
}

variable "values_template_path" {
  description = "Path to the umbrella wiring template (spark-api.demo.yaml.tftpl)."
  type        = string
}

variable "platform_namespace" {
  description = "Namespace of the platform components."
  type        = string
  default     = "spark-api-platform"
}

variable "app_namespace" {
  description = "Namespace of the application services."
  type        = string
  default     = "spark-api"
}

variable "secret_names" {
  description = "Secrets Manager names map from the secrets module."
  type        = map(string)
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

variable "bedrock_region" {
  description = "Bedrock region for LiteLLM."
  type        = string
}

variable "ecr_registry" {
  description = "ECR registry host."
  type        = string
}

variable "ecr_prefix" {
  description = "ECR repository prefix (project name)."
  type        = string
}

variable "image_tag" {
  description = "Image tag to deploy (git SHA of the source push, or latest)."
  type        = string
  default     = "latest"
}

variable "api_host" {
  description = "Public FQDN of the demo."
  type        = string
}

variable "chat_model" {
  description = "Chat model name served by LiteLLM."
  type        = string
  default     = "self-hosted/gpt-oss-120b"
}

variable "embedding_model" {
  description = "Embedding model name served by LiteLLM."
  type        = string
  default     = "self-hosted/bge-m3"
}

variable "s3_endpoint_url" {
  description = "Regional S3 endpoint."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "s3_bucket" {
  description = "Documents bucket name."
  type        = string
}

variable "auth_enabled" {
  description = "Deploy the OSS OIDC perimeter (Keycloak + oauth2-proxy) and enforce it on the ingress."
  type        = bool
  default     = true
}

variable "auth_host" {
  description = "Public Keycloak FQDN."
  type        = string
}

variable "base_domain" {
  description = "Base domain shared by the demo hostnames (cookie scope when the external OIDC provider fences every host)."
  type        = string
}

variable "external_oidc_issuer_url" {
  description = "Issuer URL of an optional corporate OIDC provider in front of the perimeter (empty = disabled)."
  type        = string
  default     = ""
}

variable "inspector_enabled" {
  description = "Deploy the demo inspector (edge-injected overlay + backend activity stream)."
  type        = bool
  default     = true
}

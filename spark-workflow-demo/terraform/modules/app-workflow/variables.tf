variable "umbrella_chart_path" {
  description = "Path to the staged upstream spark-platform umbrella chart (00-umbrella/spark-platform)."
  type        = string
}

variable "values_template_path" {
  description = "Path to the demo values template (spark-workflow.demo.yaml.tftpl)."
  type        = string
}

variable "postrender_script_path" {
  description = "Path to the helm postrenderer script (documented upstream workarounds)."
  type        = string
}

variable "docling_chart_path" {
  description = "Path to the docling-rq chart (vendored from upstream 0.2.3, helm/docling-rq)."
  type        = string
}

variable "qdrant_chart_version" {
  description = "Version of the official qdrant Helm chart (https://qdrant.github.io/qdrant-helm)."
  type        = string
  default     = "1.17.0"
}

variable "release_name" {
  description = "Helm release name (prefixes all app resource names)."
  type        = string
  default     = "spark"
}

variable "app_namespace" {
  description = "Target namespace of the application (every layer of the umbrella)."
  type        = string
  default     = "spark"
}

variable "platform_namespace" {
  description = "Namespace of the platform chart (Keycloak, LiteLLM, SpiceDB)."
  type        = string
}

variable "cluster_secret_store" {
  description = "ESO ClusterSecretStore name (the upstream db-init chart reads the RDS admin credentials through it)."
  type        = string
}

variable "rds_master_secret_name" {
  description = "Secrets Manager entry holding the RDS master credentials (properties username/password)."
  type        = string
}

variable "hosts" {
  description = "FQDNs: frontend, keycloak, temporal."
  type = object({
    frontend = string
    keycloak = string
    temporal = string
  })
}

variable "keycloak_realm" {
  description = "Keycloak realm."
  type        = string
  default     = "local"
}

variable "keycloak_client_id" {
  description = "OIDC client ID."
  type        = string
  default     = "local-client"
}

variable "auth_mode" {
  description = "Service-level auth mode of the backend pools (0.3.0 accepts strict | disabled). strict: the token Envoy forwards after the perimeter login is verified by every pool and SpiceDB permissions are enforced; disabled leaves /api/identity/me without a user."
  type        = string
  default     = "strict"
  validation {
    condition     = contains(["strict", "disabled"], var.auth_mode)
    error_message = "auth_mode must be strict or disabled (the 0.2.x dry-run mode no longer exists)."
  }
}

variable "system_user_id" {
  description = "UUID the backend records as the system actor (SYSTEM_USER_ID); the demo uses the demo user's Keycloak id."
  type        = string
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

variable "region" {
  description = "AWS region."
  type        = string
}

variable "bucket_names" {
  description = "Bucket name map (dms, temporal_payloads, temporal_archival, quarantine)."
  type        = map(string)
}

variable "vlm_model_name" {
  description = "LiteLLM model name for the vision stages (VLLM_MODEL / VLM_SUMMARY_MODEL_NAME)."
  type        = string
}

variable "litellm_url" {
  description = "In-cluster LiteLLM base URL (OpenAI-compatible, incl. /v1)."
  type        = string
  default     = "http://litellm.spark-platform.svc.cluster.local:4000/v1"
}

variable "gpu_enabled" {
  description = "Run Docling on the GPU node pool with the CUDA image."
  type        = bool
  default     = false
}

variable "docling_cpu_image" {
  description = "Docling Serve CPU image."
  type        = string
  default     = "quay.io/docling-project/docling-serve-cpu"
}

variable "docling_gpu_image" {
  description = "Docling Serve CUDA image."
  type        = string
  default     = "ghcr.io/docling-project/docling-serve-cu128"
}

variable "docling_tag" {
  description = "Docling Serve image tag."
  type        = string
  default     = "v1.14.3"
}

variable "umbrella_chart_path" {
  description = "Path to the upstream 00-spark-workflow umbrella chart (inside the submodule)."
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

variable "release_name" {
  description = "Helm release name (prefixes all app resource names)."
  type        = string
  default     = "spark"
}

variable "app_namespace" {
  description = "Target namespace of the application."
  type        = string
  default     = "spark"
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
  description = "Service-level auth mode (disabled | optional_verify_dry_run | strict). Demo default: tokens are verified against Keycloak so identity endpoints work, SpiceDB permission checks run in dry-run (upstream-designed mode for exactly this setup)."
  type        = string
  default     = "optional_verify_dry_run"
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
  description = "LiteLLM model name for the VLM enhancement stage (VLLM_MODEL override)."
  type        = string
}

variable "litellm_url" {
  description = "In-cluster LiteLLM base URL (OpenAI-compatible, incl. /v1)."
  type        = string
  default     = "http://litellm.spark-platform.svc.cluster.local:4000/v1"
}

variable "valkey_enabled" {
  description = "Use ElastiCache Valkey as docling-rq broker."
  type        = bool
  default     = true
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

variable "seed_jobs_chart_path" {
  description = "Path to the local seed-jobs chart (runs the upstream lookup-data seeds after the umbrella rollout)."
  type        = string
}

variable "seed_jobs_enabled" {
  description = "Run the upstream lookup-data seeds (project types, statuses, ...) after each umbrella change. Disable for clusters where lookup data is managed manually."
  type        = bool
  default     = true
}



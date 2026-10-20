# All environment-specific values arrive via TF_VAR_* environment variables,
# exported by the project Makefile from the untracked root .env file.
# Never commit account IDs, zone IDs, profiles or credentials.

variable "aws_region" {
  description = "Deployment region."
  type        = string
}

variable "bedrock_region" {
  description = "Region for Amazon Bedrock model invocation (may differ from aws_region)."
  type        = string
  default     = "eu-central-1"
}

variable "bedrock_vlm_model_id" {
  description = <<-EOT
    Bedrock model/inference-profile ID for the VLM enhancement stage
    (image + text input required). The upstream default VLLM_MODEL
    (gpt-oss-120b) is text-only, so a vision-capable model is mandatory.
    eu.* profiles keep cross-region routing inside the EU geography.
  EOT
  type        = string
  default     = "eu.mistral.pixtral-large-2502-v1:0"
}

variable "project_prefix" {
  description = "Name prefix for all resources."
  type        = string
  default     = "spark-demo"
}

variable "route53_zone_id" {
  description = "Public Route53 hosted zone ID."
  type        = string
}

variable "base_domain" {
  description = "Base domain of the hosted zone (no trailing dot)."
  type        = string
}

variable "acme_email" {
  description = "E-mail for the Let's Encrypt account."
  type        = string
}

# --- Hosts ----------------------------------------------------------------------
variable "workflow_host" {
  description = "Subdomain of the SPARK Workflow frontend."
  type        = string
  default     = "workflow"
}

variable "keycloak_host" {
  description = "Subdomain of Keycloak."
  type        = string
  default     = "auth-workflow"
}

variable "temporal_host" {
  description = "Subdomain of the Temporal UI."
  type        = string
  default     = "temporal-workflow"
}

variable "allowed_cidrs" {
  description = <<-EOT
    Comma-separated CIDRs allowed to reach the demo's public load balancer
    (e.g. "203.0.113.4/32,198.51.100.0/24"). Empty = open to the internet.
    Set this whenever the account's hosts must not be publicly reachable:
    a security scan of an internet-facing demo flags every host even when
    every route sits behind OIDC, because the login page itself answers
    unauthenticated callers. Enforced at L4 on the NLB, so it covers both
    :80 and :443 and every hostname at once; the same CIDRs also fence the
    public EKS API endpoint (include the operator's own address).
  EOT
  type        = string
  default     = ""
}

# --- Demo login -------------------------------------------------------------------
variable "demo_user_email" {
  description = "E-mail of the Keycloak demo user."
  type        = string
  default     = "demo.user@example.com"
}

# Optional corporate identity provider in front of the demo: any OIDC issuer
# (the operator's SSO), brokered by the demo realm. Empty = disabled, the demo
# keeps its own Keycloak login. When set, the realm's login redirects straight
# to the issuer, so no page of the demo answers to an anonymous visitor with
# anything but that redirect. The values come from .env (EXTERNAL_OIDC_*) and
# never enter this repository.
variable "external_oidc_issuer_url" {
  description = "Issuer URL of an external OIDC provider brokered by the demo realm (empty = disabled)."
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

  validation {
    condition     = (var.external_oidc_client_secret == "") == (var.external_oidc_issuer_url == "")
    error_message = "EXTERNAL_OIDC_ISSUER_URL, EXTERNAL_OIDC_CLIENT_ID and EXTERNAL_OIDC_CLIENT_SECRET must be set together (or all left empty)."
  }
}

# --- Feature flags ------------------------------------------------------------------
variable "valkey_enabled" {
  description = "Use Amazon ElastiCache for Valkey as the docling-rq broker (false = embedded Redis container)."
  type        = bool
  default     = true
}

variable "seed_jobs_enabled" {
  description = "Run the upstream lookup-data seeds (project types, statuses, ...) after each umbrella change."
  type        = bool
  default     = true
}

variable "gpu_enabled" {
  description = "Provision a GPU node group for Docling CUDA mode."
  type        = bool
  default     = false
}

# --- Sizing (all overridable for reuse) -----------------------------------------------
variable "eks_cluster_version" {
  description = "Kubernetes version."
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "Instance type of the default node group."
  type        = string
  default     = "m6i.2xlarge"
}

variable "node_count" {
  description = "Desired/min node count of the default node group."
  type        = number
  default     = 3
}

variable "node_max_count" {
  description = "Maximum node count of the default node group."
  type        = number
  default     = 5
}

variable "qdrant_node_instance_type" {
  description = "Instance type of the dedicated Qdrant node."
  type        = string
  default     = "r6i.xlarge"
}

variable "qdrant_node_count" {
  description = "Node count of the Qdrant pool (0 = share default pool)."
  type        = number
  default     = 1
}

variable "gpu_node_instance_type" {
  description = "Instance type of the GPU node group."
  type        = string
  default     = "g6.xlarge"
}

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.r6g.xlarge"
}

variable "rds_allocated_storage" {
  description = "RDS storage in GiB."
  type        = number
  default     = 100
}

variable "rds_multi_az" {
  description = "RDS Multi-AZ (demo default: false)."
  type        = bool
  default     = false
}

variable "rds_deletion_protection" {
  description = "RDS deletion protection. Demo default false so `make destroy` stays hands-off; set true for a longer-lived environment."
  type        = bool
  default     = false
}

variable "valkey_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.small"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.80.0.0/16"
}

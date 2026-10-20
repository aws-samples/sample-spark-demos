# All values arrive via TF_VAR_* from the untracked root .env (see the
# project Makefile). No account/zone/domain identifiers in git.

variable "aws_region" {
  description = "Deployment region."
  type        = string
}

variable "project_prefix" {
  description = "Name prefix for all AWS resources (must differ from other demos in the same account)."
  type        = string
  default     = "spark-api-demo"
}

variable "route53_zone_id" {
  description = "Public Route53 hosted zone the demo hosts are created in."
  type        = string
}

variable "base_domain" {
  description = "Base domain of the hosted zone (without trailing dot)."
  type        = string
}

variable "acme_email" {
  description = "E-mail for the Let's Encrypt account."
  type        = string
}

variable "api_host" {
  description = "Subdomain host of the SPARK API demo (frontend + APIs, path-routed)."
  type        = string
  default     = "api-suite"
}

variable "auth_host" {
  description = "Subdomain host of the Keycloak login (OSS OIDC perimeter)."
  type        = string
  default     = "auth-api"
}

variable "auth_enabled" {
  description = "Deploy and enforce the OIDC perimeter (Keycloak + oauth2-proxy)."
  type        = bool
  default     = true
}

# Optional corporate identity provider in front of the perimeter: any OIDC
# issuer (the operator's SSO). Empty = disabled, the demo keeps its own
# Keycloak login. When set, oauth2-proxy authenticates against this issuer and
# the Keycloak host is fenced behind the same check, so no page of the demo
# answers anonymously. The values come from .env (EXTERNAL_OIDC_*) and never
# enter this repository.
variable "external_oidc_issuer_url" {
  description = "Issuer URL of an external OIDC provider placed in front of the demo (empty = disabled)."
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

variable "bedrock_region" {
  description = "Region for Amazon Bedrock model invocation (gpt-oss-120b on-demand and the eu. Claude Haiku 4.5 profile are available in eu-central-1; may differ from aws_region — a different region means prompts and documents cross a region boundary)."
  type        = string
  default     = "eu-central-1"
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

# --- Sizing (all overridable via .env) -----------------------------------------
variable "node_instance_type" {
  description = "Instance type of the default node group."
  type        = string
  default     = "m6i.2xlarge"
}

variable "node_count" {
  description = "Desired node count of the default node group."
  type        = number
  default     = 3
}

variable "stateful_node_count" {
  description = "Node count of the dedicated stateful pool (0 = disabled)."
  type        = number
  default     = 1
}

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.r6g.large"
}

variable "rds_deletion_protection" {
  description = "RDS deletion protection. Demo default false so `make destroy` stays hands-off; set true for a longer-lived environment."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Image tag of the deployed services (git SHA of the pushed source, or latest)."
  type        = string
  default     = "latest"
}

locals {
  name            = var.project_prefix
  api_fqdn        = "${var.api_host}.${var.base_domain}"
  auth_fqdn       = "${var.auth_host}.${var.base_domain}"
  frontend_origin = "https://${var.api_host}.${var.base_domain}"

  # TF_VAR_* values are always strings, so the CIDR set arrives comma
  # separated (one scalar per .env key, like every other override here)
  # and is split into the list the Service field expects.
  allowed_cidrs = [
    for c in split(",", var.allowed_cidrs) : trimspace(c) if trimspace(c) != ""
  ]

  tags = {
    Project   = "spark-api-demo"
    ManagedBy = "terraform"
  }
}

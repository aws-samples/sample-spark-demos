variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "region" {
  description = "AWS region of the cluster."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (AWS Load Balancer Controller)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for demo DNS records and DNS-01 challenges."
  type        = string
}

variable "base_domain" {
  description = "Base domain of the hosted zone (external-dns domain filter)."
  type        = string
}

variable "acme_email" {
  description = "E-mail address for the Let's Encrypt account."
  type        = string
}

variable "eso_secret_arns" {
  description = "Secrets Manager ARNs the External Secrets Operator may read."
  type        = list(string)
}

variable "eso_kms_key_arns" {
  description = "KMS key ARNs the External Secrets Operator may decrypt with (the customer-managed key encrypting the Secrets Manager entries)."
  type        = list(string)
}

variable "cluster_config_chart_path" {
  description = "Local path to the cluster-config chart (ClusterSecretStore, ClusterIssuer)."
  type        = string
}

variable "bedrock_region" {
  description = "Region used for Amazon Bedrock model invocation (LiteLLM backend)."
  type        = string
}

variable "platform_namespace" {
  description = "Namespace for platform components (RabbitMQ, Neo4j, Qdrant, LiteLLM)."
  type        = string
  default     = "spark-api-platform"
}

variable "app_namespace" {
  description = "Namespace for the SPARK API application umbrella."
  type        = string
  default     = "spark-api"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the public NLB (empty = open to the internet)."
  type        = list(string)
  default     = []
}

# --- Chart versions (override when upstream moves on) --------------------------
variable "chart_version_aws_lb_controller" {
  description = "Chart version of aws-load-balancer-controller (eks-charts)."
  type        = string
  default     = "3.5.0"
}

variable "chart_version_external_secrets" {
  description = "Chart version of external-secrets."
  type        = string
  default     = "2.8.0"
}

variable "chart_version_cert_manager" {
  description = "Chart version of cert-manager (jetstack, v-prefixed)."
  type        = string
  default     = "v1.21.1"
}

variable "chart_version_ingress_nginx" {
  description = "Chart version of ingress-nginx."
  type        = string
  default     = "4.13.3"
}

variable "chart_version_external_dns" {
  description = "Chart version of external-dns (null = latest)."
  type        = string
  default     = null
}

variable "chart_version_metrics_server" {
  description = "Chart version of metrics-server (null = latest)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all AWS resources."
  type        = map(string)
  default     = {}
}

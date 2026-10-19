# SPARK API on AWS EKS — demo environment root module.
#
# Stage 1 (this file): network, EKS, RDS, S3, secrets — the foundation.
# Stage 2 (spec tasks 1.3/3.x): registry-build (ECR + CodeBuild/CodePipeline),
# k8s addons (ingress-nginx, ESO, cert-manager, external-dns), in-cluster
# platform (RabbitMQ operator, Neo4j, Qdrant, LiteLLM) and the app umbrella.

# Guard: `auth_enabled=false` removes the OIDC perimeter, so it is only
# allowed together with a non-empty NLB/EKS allowlist — otherwise every
# service would answer anonymous internet callers.
resource "terraform_data" "perimeter_guard" {
  input = {
    auth_enabled  = var.auth_enabled
    allowed_cidrs = local.allowed_cidrs
  }

  lifecycle {
    precondition {
      condition     = var.auth_enabled || length(local.allowed_cidrs) > 0
      error_message = "auth_enabled=false disables the OIDC perimeter. Set DEMO_ALLOWED_CIDRS (allowed_cidrs) to the presenter's CIDRs first, or keep SPARK_API_AUTH_ENABLED=true."
    }
  }
}

module "network" {
  source = "../../modules/network"

  name = local.name
  tags = local.tags
}

# One customer-managed key for everything the environment encrypts at rest
# (Secrets Manager, S3 incl. the build source bucket, ECR, RDS Performance
# Insights + log exports, CodeBuild and its log group).
module "kms" {
  source = "../../modules/kms"

  name = local.name
  cloudwatch_log_group_names = [
    "/aws/rds/instance/${local.name}/*", # rds module log exports
    "/codebuild/${local.name}-images",   # registry-build module
  ]
  tags = local.tags
}

module "eks" {
  # Destroy-order guard, part 2 (observed in the clean destroy test): eks
  # references only subnet IDs, so the NAT gateway/IGW/public subnets have
  # no dependents and get destroyed in parallel with the k8s teardown. The
  # private nodes then lose all egress — the LB controller could no longer
  # reach the AWS APIs (i/o timeouts) and the NLB deletion never happened.
  # Depending on the whole network module keeps NAT/IGW alive until eks
  # (and transitively all addons/workloads) are gone.
  depends_on = [module.network]

  source = "../../modules/eks"

  name               = local.name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  # The same allowlist that fronts the NLB also fences the public EKS API
  # endpoint (empty = open, see variables.tf).
  public_access_cidrs = local.allowed_cidrs

  default_node_instance_type = var.node_instance_type
  default_node_desired       = var.node_count
  default_node_min           = min(var.node_count, 3)
  default_node_max           = max(var.node_count + 2, 5)
  stateful_node_count        = var.stateful_node_count

  tags = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name        = local.name
  kms_key_arn = module.kms.key_arn
  rds_host    = module.rds.host
  rds_port    = module.rds.port
  auth_host   = local.auth_fqdn

  s3_endpoint_url      = module.s3.s3_endpoint_url
  s3_region            = var.aws_region
  s3_bucket_names      = module.s3.bucket_names
  s3_access_key_id     = module.s3.app_access_key_id
  s3_secret_access_key = module.s3.app_secret_access_key

  tags = local.tags
}

module "rds" {
  source = "../../modules/rds-postgres"

  name                = local.name
  vpc_id              = module.network.vpc_id
  private_subnet_ids  = module.network.private_subnet_ids
  instance_class      = var.rds_instance_class
  deletion_protection = var.rds_deletion_protection
  kms_key_arn         = module.kms.key_arn

  allowed_security_groups = {
    eks_nodes   = module.eks.node_security_group_id
    eks_cluster = module.eks.cluster_security_group_id
  }

  master_password = module.secrets.rds_master_password

  tags = local.tags
}

module "registry_build" {
  source = "../../modules/registry-build"

  name          = local.name
  services_file = "${path.module}/../../../pipeline/services.txt"
  kms_key_arn   = module.kms.key_arn

  tags = local.tags
}

module "k8s_addons" {
  source = "../../modules/k8s-addons"

  # Destroy-order guard (observed during the destroy test): referencing only
  # module.eks OUTPUTS creates edges to the cluster resource, not to the
  # node groups — terraform deleted the node groups in parallel with the
  # helm uninstalls. Every controller died mid-teardown: the LB controller
  # left the ingress-nginx NLB + target groups orphaned (blocking subnet/IGW
  # deletion for 10+ min), ESO left ExternalSecrets stuck on their cleanup
  # finalizer (helm release frozen in "uninstalling"), and the EBS CSI
  # driver could no longer delete PVs. Module-level depends_on makes ALL
  # addon resources depend on ALL eks resources incl. node groups, so on
  # destroy the nodes outlive every workload teardown.
  depends_on = [module.eks]

  cluster_name    = module.eks.cluster_name
  region          = var.aws_region
  vpc_id          = module.network.vpc_id
  route53_zone_id = var.route53_zone_id
  base_domain     = var.base_domain
  acme_email      = var.acme_email
  bedrock_region  = var.bedrock_region

  eso_secret_arns           = module.secrets.secret_arns
  eso_kms_key_arns          = [module.kms.key_arn]
  cluster_config_chart_path = "${path.module}/../../../helm/cluster-config"
  allowed_cidrs             = local.allowed_cidrs

  tags = local.tags
}

module "s3" {
  source = "../../modules/s3"

  name            = local.name
  frontend_origin = local.frontend_origin
  kms_key_arn     = module.kms.key_arn

  # documents: tex2pdf outputs & Co. — cors=true because delivery to the
  # browser may use presigned URLs (exact wiring in spec task 4.2).
  buckets = {
    documents = { cors = true }
  }

  tags = local.tags
}

module "app" {
  source = "../../modules/app"

  # See k8s_addons: keep the node groups alive until the workload releases
  # (and their hook jobs / ExternalSecrets) are fully uninstalled.
  depends_on = [module.k8s_addons]

  platform_chart_path  = "${path.module}/../../../helm/platform"
  umbrella_chart_path  = "${path.module}/../../../helm/umbrella"
  values_template_path = "${path.module}/../../../helm/values/spark-api.demo.yaml.tftpl"

  platform_namespace = module.k8s_addons.platform_namespace
  app_namespace      = module.k8s_addons.app_namespace

  secret_names   = module.secrets.secret_names
  rds_host       = module.rds.host
  rds_port       = module.rds.port
  bedrock_region = var.bedrock_region

  ecr_registry = module.registry_build.ecr_registry
  ecr_prefix   = local.name
  image_tag    = var.image_tag

  api_host        = local.api_fqdn
  auth_host       = local.auth_fqdn
  auth_enabled    = var.auth_enabled
  s3_endpoint_url = module.s3.s3_endpoint_url
  region          = var.aws_region
  s3_bucket       = module.s3.bucket_names["documents"]
}

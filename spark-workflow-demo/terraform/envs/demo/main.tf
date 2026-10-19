# SPARK Workflow on AWS EKS — demo environment root module.
#
# Provisioning order:
#   network → eks → (secrets ⇄ rds/valkey/s3) → k8s-addons
# The application itself (platform chart + upstream 00-spark-workflow umbrella)
# is layered on top — see ../../helm and the app-deploy module (next phase).

locals {
  name = var.project_prefix

  frontend_fqdn = "${var.workflow_host}.${var.base_domain}"
  keycloak_fqdn = "${var.keycloak_host}.${var.base_domain}"
  temporal_fqdn = "${var.temporal_host}.${var.base_domain}"

  # App-facing name of the vision model (keeps the upstream `self-hosted/`
  # prefix so LLM activities route to the llm-custom task queue). Served by
  # LiteLLM (app-platform) and referenced by VLLM_MODEL in the workflow
  # overlay — single source here so both stay in sync.
  vlm_model_name = "self-hosted/pixtral-large"

  # TF_VAR_* values are always strings, so the CIDR set arrives comma
  # separated (one scalar per .env key, like every other override here)
  # and is split into the list the Service field expects.
  allowed_cidrs = [
    for c in split(",", var.allowed_cidrs) : trimspace(c) if trimspace(c) != ""
  ]

  tags = {
    Project   = "spark-workflow-demo"
    ManagedBy = "terraform"
  }
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr
  tags     = local.tags
}

# One customer-managed key for everything the environment encrypts at rest
# (Secrets Manager, S3, RDS Performance Insights + log exports, Valkey).
module "kms" {
  source = "../../modules/kms"

  name = local.name
  # RDS exports postgresql/upgrade logs into these groups (rds module).
  cloudwatch_log_group_names = ["/aws/rds/instance/${local.name}/*"]
  tags                       = local.tags
}

module "eks" {
  source = "../../modules/eks"

  # Destroy-order guard, part 2 (observed in the spark-api-demo destroy
  # test): eks references only subnet IDs, so NAT/IGW/public subnets have
  # no dependents and die in parallel with the k8s teardown — private
  # nodes lose egress and the LB controller cannot delete the NLB
  # (AWS API i/o timeouts). Depend on the whole network module.
  depends_on = [module.network]

  name               = local.name
  cluster_version    = var.eks_cluster_version
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  # The same allowlist that fronts the NLB also fences the public EKS API
  # endpoint (empty = open, see variables.tf).
  public_access_cidrs = local.allowed_cidrs

  default_node_instance_type = var.node_instance_type
  default_node_min           = var.node_count
  default_node_desired       = var.node_count
  default_node_max           = var.node_max_count

  qdrant_node_instance_type = var.qdrant_node_instance_type
  qdrant_node_count         = var.qdrant_node_count

  gpu_enabled            = var.gpu_enabled
  gpu_node_instance_type = var.gpu_node_instance_type

  tags = local.tags
}

module "s3" {
  source = "../../modules/s3"

  name            = local.name
  frontend_origin = "https://${local.frontend_fqdn}"
  kms_key_arn     = module.kms.key_arn
  tags            = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name                     = local.name
  kms_key_arn              = module.kms.key_arn
  rds_host                 = module.rds.host
  rds_port                 = module.rds.port
  s3_endpoint_url          = module.s3.s3_endpoint_url
  s3_region                = var.aws_region
  s3_bucket_names          = module.s3.bucket_names
  s3_access_key_id         = module.s3.app_access_key_id
  s3_secret_access_key     = module.s3.app_secret_access_key
  valkey_url               = var.valkey_enabled ? module.valkey[0].redis_url : null
  keycloak_demo_user_email = var.demo_user_email
  keycloak_host            = local.keycloak_fqdn

  tags = local.tags
}

module "rds" {
  source = "../../modules/rds-postgres"

  name               = local.name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  allowed_security_groups = {
    cluster = module.eks.cluster_security_group_id
    nodes   = module.eks.node_security_group_id
  }

  instance_class      = var.rds_instance_class
  allocated_storage   = var.rds_allocated_storage
  multi_az            = var.rds_multi_az
  deletion_protection = var.rds_deletion_protection
  master_password     = module.secrets.rds_master_password
  kms_key_arn         = module.kms.key_arn

  tags = local.tags
}

module "valkey" {
  source = "../../modules/elasticache-valkey"
  count  = var.valkey_enabled ? 1 : 0

  name               = local.name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  allowed_security_groups = {
    cluster = module.eks.cluster_security_group_id
    nodes   = module.eks.node_security_group_id
  }

  node_type   = var.valkey_node_type
  auth_token  = module.secrets.valkey_auth_token
  kms_key_arn = module.kms.key_arn

  tags = local.tags
}

module "k8s_addons" {
  source = "../../modules/k8s-addons"

  # Destroy-order guard (observed during the spark-api-demo destroy test):
  # output references alone let terraform delete the node groups in
  # parallel with the helm uninstalls — every controller (LB controller,
  # ESO, EBS CSI) died mid-teardown, orphaning the NLB, freezing
  # ExternalSecret finalizers and leaking EBS volumes. Module-level
  # depends_on keeps the nodes alive until all addons are gone; app_platform
  # and app_workflow already chain onto k8s_addons.
  depends_on = [module.eks]

  cluster_name    = module.eks.cluster_name
  region          = var.aws_region
  vpc_id          = module.network.vpc_id
  route53_zone_id = var.route53_zone_id
  base_domain     = var.base_domain
  acme_email      = var.acme_email

  frontend_fqdn = local.frontend_fqdn
  keycloak_fqdn = local.keycloak_fqdn
  temporal_fqdn = local.temporal_fqdn
  allowed_cidrs = local.allowed_cidrs

  eso_secret_arns           = module.secrets.secret_arns
  eso_kms_key_arns          = [module.kms.key_arn]
  bedrock_region            = var.bedrock_region
  cluster_config_chart_path = "${path.module}/../../../helm/cluster-config"

  tags = local.tags
}

module "app_platform" {
  source = "../../modules/app-platform"

  chart_path           = "${path.module}/../../../helm/platform"
  platform_namespace   = module.k8s_addons.platform_namespace
  app_namespace        = module.k8s_addons.app_namespace
  cluster_secret_store = module.k8s_addons.cluster_secret_store_name
  secret_names         = module.secrets.secret_names

  hosts = {
    frontend = local.frontend_fqdn
    keycloak = local.keycloak_fqdn
    temporal = local.temporal_fqdn
  }

  rds_host        = module.rds.host
  rds_port        = module.rds.port
  s3_endpoint_url = module.s3.s3_endpoint_url
  s3_region       = var.aws_region
  s3_dms_bucket   = module.s3.bucket_names["dms"]
  # Seed from the unmodified upstream submodule.
  seed_file_path = "${path.module}/../../../spark-workflow/scripts/data/gesetze-normen-seed.sql.gz"

  bedrock_region       = var.bedrock_region
  bedrock_vlm_model_id = var.bedrock_vlm_model_id
  vlm_model_name       = local.vlm_model_name
  valkey_enabled       = var.valkey_enabled

  # Explicit module-level ordering: the platform chart's pre-install hooks
  # create ExternalSecrets, which the ESO validating webhook must admit —
  # variable references alone do not guarantee the addon releases are done.
  depends_on = [module.k8s_addons]
}

module "app_workflow" {
  source = "../../modules/app-workflow"

  # Staged copy of the upstream charts (Makefile target `stage-charts`):
  # `helm dependency update` writes build artifacts (charts/, Chart.lock)
  # which must never dirty the submodule working tree.
  umbrella_chart_path    = "${path.module}/../../../.build/spark-workflow-charts/00-spark-workflow"
  values_template_path   = "${path.module}/../../../helm/values/spark-workflow.demo.yaml.tftpl"
  postrender_script_path = abspath("${path.module}/../../../helm/postrender-spark-workflow.sh")
  seed_jobs_chart_path   = "${path.module}/../../../helm/seed-jobs"

  app_namespace = module.k8s_addons.app_namespace

  hosts = {
    frontend = local.frontend_fqdn
    keycloak = local.keycloak_fqdn
    temporal = local.temporal_fqdn
  }

  rds_host        = module.rds.host
  rds_port        = module.rds.port
  s3_endpoint_url = module.s3.s3_endpoint_url
  region          = var.aws_region
  bucket_names    = module.s3.bucket_names

  vlm_model_name    = local.vlm_model_name
  valkey_enabled    = var.valkey_enabled
  gpu_enabled       = var.gpu_enabled
  seed_jobs_enabled = var.seed_jobs_enabled

  # Platform layer (Keycloak, LiteLLM, db-init, ExternalSecrets) must exist first.
  depends_on = [module.app_platform]
}

# Deploys the demo workloads: the platform chart (RabbitMQ, Neo4j, Qdrant,
# LiteLLM+TEI, db-init, ExternalSecrets) and the umbrella (all SPARK API
# services from the wiring matrix).

resource "helm_release" "platform" {
  name      = "spark-api-platform"
  chart     = var.platform_chart_path
  namespace = var.platform_namespace

  timeout = 1200

  values = [yamlencode({
    appNamespace = var.app_namespace
    # checkov:skip=CKV_SECRET_6: Name of the ESO ClusterSecretStore, not a credential
    clusterSecretStore = "aws-secrets-manager"
    secretsManager = {
      rdsMaster   = var.secret_names["rds_master"]
      rdsApp      = var.secret_names["rds_app"]
      rabbitmq    = var.secret_names["rabbitmq"]
      neo4j       = var.secret_names["neo4j"]
      litellm     = var.secret_names["litellm"]
      bizlog      = var.secret_names["bizlog"]
      keycloak    = var.secret_names["keycloak"]
      oauth2Proxy = var.secret_names["oauth2_proxy"]
      s3App       = var.secret_names["s3_app"]
    }
    rds = {
      host = var.rds_host
      port = var.rds_port
    }
    litellm = {
      bedrockRegion = var.bedrock_region
    }
    auth = {
      enabled = var.auth_enabled
      host    = var.auth_host
      apiHost = var.api_host
    }
  })]
}

locals {
  umbrella_values = templatefile(var.values_template_path, {
    auth_enabled       = var.auth_enabled
    inspector_enabled  = var.inspector_enabled
    bedrock_region     = var.bedrock_region
    ecr_registry       = var.ecr_registry
    ecr_prefix         = var.ecr_prefix
    image_tag          = var.image_tag
    api_host           = var.api_host
    rds_host           = var.rds_host
    rds_port           = tostring(var.rds_port)
    app_namespace      = var.app_namespace
    platform_namespace = var.platform_namespace
    # No /v1 suffix: the Mistral SDK (9 services) appends /v1/chat/completions
    # itself — with the suffix every call became /v1/v1/... and LiteLLM
    # answered 404 (observed: Vollstaendigkeitspruefung flipped to FEHLER in
    # 40 ms, SDKError "Status 404 {\"detail\":\"Not Found\"}"). LiteLLM serves
    # prefixed AND unprefixed OpenAI routes, so OpenAI-SDK consumers
    # (base_url + /chat/completions) keep working — verified live against
    # /chat/completions, /v1/chat/completions and /embeddings (all 200).
    litellm_url     = "http://litellm.${var.platform_namespace}.svc.cluster.local:4000"
    litellm_base    = "http://litellm.${var.platform_namespace}.svc.cluster.local:4000"
    chat_model      = var.chat_model
    embedding_model = var.embedding_model
    s3_endpoint     = var.s3_endpoint_url
    s3_region       = var.region
    s3_bucket       = var.s3_bucket
  })
}

resource "helm_release" "umbrella" {
  name      = "spark-api"
  chart     = var.umbrella_chart_path
  namespace = var.app_namespace

  # ~23 deployments incl. startup migrations; verify.sh checks convergence.
  wait    = false
  timeout = 1800

  values = [local.umbrella_values]

  depends_on = [helm_release.platform]
}

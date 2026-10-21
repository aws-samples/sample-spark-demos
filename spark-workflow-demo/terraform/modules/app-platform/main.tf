# Deploys the demo platform layer (Keycloak, oauth2-proxy, LiteLLM, TEI,
# db-init, ExternalSecrets, HTTPRoutes) via the local spark-platform chart.
# The upstream 00-spark-workflow umbrella is layered on top of this.

# Seed file from the unmodified upstream submodule, staged into S3 so the
# in-cluster db-init job can import it into the gesetze-normen database.
resource "aws_s3_object" "gesetze_normen_seed" {
  bucket = var.s3_dms_bucket
  key    = "bootstrap/gesetze-normen-seed.sql.gz"
  source = var.seed_file_path
  # source_hash, not etag: the bucket uses SSE-KMS, where the object's ETag is
  # not the content MD5, so `etag = filemd5()` reads as drift and re-uploads
  # the seed on every apply (observed: etag f98c... vs filemd5 fb7c... with
  # an unchanged file).
  source_hash = filemd5(var.seed_file_path)
}

resource "helm_release" "platform" {
  name      = "spark-platform"
  chart     = var.chart_path
  namespace = var.platform_namespace

  # Hooks (db-init, keycloak-bootstrap) can take a while on first install.
  timeout = 1800
  wait    = true

  values = [yamlencode({
    appNamespace       = var.app_namespace
    clusterSecretStore = var.cluster_secret_store

    secretsManager = merge({
      rdsMaster   = var.secret_names["rds_master"]
      rdsApp      = var.secret_names["rds_app"]
      rdsTemporal = var.secret_names["rds_temporal"]
      rdsKeycloak = var.secret_names["rds_keycloak"]
      rdsSpicedb  = var.secret_names["rds_spicedb"]
      s3App       = var.secret_names["s3_app"]
      keycloak    = var.secret_names["keycloak"]
      oauth2Proxy = var.secret_names["oauth2_proxy"]
      spicedb     = var.secret_names["spicedb"]
      litellm     = var.secret_names["litellm"]
      valkey      = var.secret_names["valkey"]
    }, contains(keys(var.secret_names), "external_oidc") ? { externalOidc = var.secret_names["external_oidc"] } : {})

    keycloak = {
      demoUser = { id = var.demo_user_id }
      externalOidc = {
        enabled   = var.external_oidc_issuer_url != ""
        issuerUrl = var.external_oidc_issuer_url
      }
    }

    hosts = {
      frontend = var.hosts.frontend
      keycloak = var.hosts.keycloak
      temporal = var.hosts.temporal
    }

    rds = {
      host = var.rds_host
      port = var.rds_port
    }

    s3 = {
      endpointUrl   = var.s3_endpoint_url
      region        = var.s3_region
      dmsBucket     = var.s3_dms_bucket
      seedObjectKey = aws_s3_object.gesetze_normen_seed.key
    }

    litellm = {
      bedrockRegion     = var.bedrock_region
      bedrockModelId    = var.bedrock_model_id
      vlmModelName      = var.vlm_model_name
      bedrockVlmModelId = var.bedrock_vlm_model_id
    }

    # Secrets the upstream 0.3.0 umbrella references in the app namespace
    # (names from a full `helm template` of spark-platform with our overlay;
    # the render check lists them: .kiro/tools/render-workflow.sh).
    appSecrets = concat(
      # The agent data services keep one credentials Secret each (upstream
      # names); every one of them maps to the shared spark_app role.
      [for name in [
        "gesetze-normen-db-credentials",
        "gesetzesbegruendung-db-credentials",
        "jura-db-credentials",
        "rechtsaenderungs-monitoring-db-credentials",
        # modul-rechtsmethodik's legal-terms store (rechtsbegriffe database).
        "postgres-cluster-user",
        # The 15 backend pools: runtime and migration role (DB_USER /
        # DB_MIGRATE_USER) are the same role in the demo.
        "spark-backend-db",
        ] : {
        name = name
        data = [
          { secretKey = "username", remoteRef = { key = var.secret_names["rds_app"], property = "username" } },
          { secretKey = "password", remoteRef = { key = var.secret_names["rds_app"], property = "password" } },
        ]
      }],
      [
        # Everything the backend pools need that is not configuration, loaded
        # with envFrom (global.backend.secretRefs). FPP_* (optional, all five
        # or none) and ARCHIVAL_ENCRYPTION_KEY (archival off) are left out on
        # purpose.
        {
          name = "spark-backend-secrets"
          data = [
            { secretKey = "AUTH_CLIENT_SECRET", remoteRef = { key = var.secret_names["keycloak"], property = "client_secret" } },
            { secretKey = "AUTH_PRIVILEGED_CLIENT_SECRET", remoteRef = { key = var.secret_names["keycloak"], property = "client_secret" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "QUARANTINE_S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "QUARANTINE_S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
          ]
        },
        # Temporal server persistence password (official chart existingSecret).
        {
          name = "temporal-db-credentials"
          data = [
            { secretKey = "password", remoteRef = { key = var.secret_names["rds_temporal"], property = "password" } },
          ]
        },
        # Temporal payload offloading S3 credentials (agent modules, llm-client).
        {
          name = "temporal-s3-secrets"
          data = [
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
          ]
        },
        # Prompt-injection guard: the module downloads a public HF model —
        # the token must be EMPTY (anonymous); any filler breaks with 401.
        {
          name = "injection-model-secret"
          data = [
            { secretKey = "INJECTION_MODEL_TOKEN", remoteRef = { key = var.secret_names["litellm"], property = "injection_model_token" } },
          ]
        },
        # LiteLLM master key — both key spellings used across charts.
        {
          name = "litellm-proxy-credentials"
          data = [
            { secretKey = "LITELLM_MASTER_KEY", remoteRef = { key = var.secret_names["litellm"], property = "master_key" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "master-key", remoteRef = { key = var.secret_names["litellm"], property = "master_key" } },
          ]
        },
        # Docling OAuth client (points at the demo realm; in-cluster Docling
        # does not enforce it, kept for upstream contract compatibility).
        {
          name = "docling-keycloak-secrets"
          data = [
            { secretKey = "KEYCLOAK_CLIENT_ID", remoteRef = { key = var.secret_names["keycloak"], property = "client_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "KEYCLOAK_CLIENT_SECRET", remoteRef = { key = var.secret_names["keycloak"], property = "client_secret" } },
          ]
        },
      ]
    )
  })]

  depends_on = [aws_s3_object.gesetze_normen_seed]
}

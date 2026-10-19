# Deploys the demo platform layer (Keycloak, oauth2-proxy, LiteLLM, TEI,
# db-init, ExternalSecrets, HTTPRoutes) via the local spark-platform chart.
# The upstream 00-spark-workflow umbrella is layered on top of this.

# Seed file from the unmodified upstream submodule, staged into S3 so the
# in-cluster db-init job can import it into the gesetze-normen database.
resource "aws_s3_object" "gesetze_normen_seed" {
  bucket = var.s3_dms_bucket
  key    = "bootstrap/gesetze-normen-seed.sql.gz"
  source = var.seed_file_path
  etag   = filemd5(var.seed_file_path)
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

    secretsManager = {
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
      valkey      = var.valkey_enabled ? var.secret_names["valkey"] : ""
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

    # Secrets the upstream umbrella references in the app namespace
    # (extracted from a full `helm template` render of 00-spark-workflow).
    appSecrets = concat(
      # Per-service DB user secrets → all map to the shared spark_app role.
      [for name in [
        "project-logic-db-user",
        "dms-db-user",
        "formal-check-db-user",
        "examination-db-user",
        "comment-service-db-user",
        "plausibility-notes-db-user",
        "objections-service-db-user",
        "supplementary-requests-db-user",
        "admin-file-draft-db-user",
        "temporal-job-service-db-user",
        "identity-management-db-user",
        "gesetze-normen-db-user",
        "fpp-db-user",
        "feedback-service-db-user",
        "jura-db-credentials",
        "begruendungen-db-credentials",
        "rechtsaenderungsmonitoring-credentials",
        ] : {
        name = name
        data = [
          { secretKey = "username", remoteRef = { key = var.secret_names["rds_app"], property = "username" } },
          { secretKey = "password", remoteRef = { key = var.secret_names["rds_app"], property = "password" } },
        ]
      }],
      [
        # Temporal server persistence password (official chart existingSecret).
        {
          name = "temporal-db-credentials"
          data = [
            { secretKey = "password", remoteRef = { key = var.secret_names["rds_temporal"], property = "password" } },
          ]
        },
        # Temporal payload offloading S3 credentials (both names the source
        # charts reference — the umbrella overrides only some entries).
        {
          name = "temporal-s3-secrets"
          data = [
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
          ]
        },
        {
          name = "agent-orchestration-temporal-s3-secrets"
          data = [
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "TEMPORAL_S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
          ]
        },
        # Per-service LiteLLM API-key secrets (jura/gesetzesbegruendung chunking).
        {
          name = "jura-litellm"
          data = [
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "master-key", remoteRef = { key = var.secret_names["litellm"], property = "master_key" } },
          ]
        },
        {
          name = "begruendung-litellm"
          data = [
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "master-key", remoteRef = { key = var.secret_names["litellm"], property = "master_key" } },
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
        # Document management S3 credentials (app + quarantine).
        {
          name = "dms-secrets"
          data = [
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "S3_ACCESS_KEY_ID", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            # checkov:skip=CKV_SECRET_6: Kubernetes secret KEY name + Secrets Manager reference, not a value
            { secretKey = "S3_SECRET_ACCESS_KEY", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
          ]
        },
        {
          name = "dms-quarantine-bucket-credentials"
          data = [
            { secretKey = "access-key", remoteRef = { key = var.secret_names["s3_app"], property = "access_key_id" } },
            { secretKey = "secret-key", remoteRef = { key = var.secret_names["s3_app"], property = "secret_access_key" } },
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
        # OIDC client credentials for services talking to Keycloak.
        {
          name = "keycloak-client"
          data = [
            { secretKey = "client_id", remoteRef = { key = var.secret_names["keycloak"], property = "client_id" } },
            { secretKey = "client_secret", remoteRef = { key = var.secret_names["keycloak"], property = "client_secret" } },
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
        # FPP portal integration placeholders (integration out of demo scope).
        {
          name = "fpp-secrets"
          data = [
            { secretKey = "oidc_client_id", remoteRef = { key = var.secret_names["fpp"], property = "oidc_client_id" } },
            { secretKey = "oidc_client_secret", remoteRef = { key = var.secret_names["fpp"], property = "oidc_client_secret" } },
            { secretKey = "oidc_user", remoteRef = { key = var.secret_names["fpp"], property = "oidc_user" } },
            { secretKey = "oidc_password", remoteRef = { key = var.secret_names["fpp"], property = "oidc_password" } },
            { secretKey = "oidc_token_url", remoteRef = { key = var.secret_names["fpp"], property = "oidc_token_url" } },
          ]
        },
      ]
    )
  })]

  depends_on = [aws_s3_object.gesetze_normen_seed]
}

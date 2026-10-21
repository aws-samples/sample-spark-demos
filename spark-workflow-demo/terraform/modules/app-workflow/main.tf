# Deploys the unmodified upstream spark-platform umbrella (spark-workflow
# 0.3.0, helm/charts/00-umbrella/spark-platform) from the git submodule,
# configured through the rendered demo overlay
# (helm/values/spark-workflow.demo.yaml.tftpl), plus the two in-cluster
# services the 0.3.0 charts treat as external endpoints: Qdrant (official
# chart) and Docling (docling-rq chart vendored from upstream 0.2.3).
#
# dependency_update resolves the umbrella's file:// chart dependencies and the
# one remote dependency (official Temporal chart, inside the upstream wrapper)
# at apply time — the submodule stays untouched apart from Helm's charts/
# build artifacts in the staged copy (.build/, gitignored).

locals {
  release_dns = "${var.app_namespace}.svc.cluster.local"

  demo_values = templatefile(var.values_template_path, {
    frontend_host        = var.hosts.frontend
    keycloak_host        = var.hosts.keycloak
    temporal_host        = var.hosts.temporal
    keycloak_realm       = var.keycloak_realm
    keycloak_client_id   = var.keycloak_client_id
    auth_mode            = var.auth_mode
    release_name         = var.release_name
    app_namespace        = var.app_namespace
    cluster_secret_store = var.cluster_secret_store
    rds_master_secret    = var.rds_master_secret_name
    rds_host             = var.rds_host
    rds_port             = tostring(var.rds_port)
    s3_endpoint          = var.s3_endpoint_url
    region               = var.region
    bucket_dms           = var.bucket_names["dms"]
    bucket_temporal      = var.bucket_names["temporal_payloads"]
    bucket_archival      = var.bucket_names["temporal_archival"]
    bucket_quarantine    = var.bucket_names["quarantine"]
    litellm_url          = var.litellm_url
    vlm_model_name       = var.vlm_model_name
    spicedb_endpoint     = "spicedb.${var.platform_namespace}.svc.cluster.local:50051"
    qdrant_host          = "${helm_release.qdrant.name}.${local.release_dns}"
    docling_host         = "${var.release_name}-docling-rq.${local.release_dns}"
    temporal_frontend    = "${var.release_name}-temporal-frontend.${local.release_dns}:7233"
    unoserver_host       = "${var.release_name}-unoserver.${local.release_dns}"
    clamav_url           = "http://${var.release_name}-clamav.${local.release_dns}:6000"
    otel_endpoint        = "http://otel-collector.${local.release_dns}:4317"
    machine_identity_proxy = "http://machine-identity-proxy.${local.release_dns}"
    system_user_id       = var.system_user_id
  })
}

resource "helm_release" "spark_workflow" {
  name      = var.release_name
  chart     = var.umbrella_chart_path
  namespace = var.app_namespace

  dependency_update = true
  timeout           = 1800
  # The umbrella spans ~110 resources incl. the Temporal schema jobs and the
  # db-init hooks; do not block the apply on full readiness — the verify
  # script checks convergence.
  wait = false

  # Documented upstream workarounds (see helm/postrender-spark-workflow.sh).
  postrender {
    binary_path = var.postrender_script_path
  }

  values = [
    local.demo_values,
    # The postrenderer script content is not tracked by the provider —
    # embed its hash as a harmless global label so script changes always
    # trigger a helm upgrade.
    yamlencode({
      global = {
        labels = {
          "spark-demo.config/postrender-hash" = substr(filemd5(var.postrender_script_path), 0, 12)
        }
      }
    }),
  ]

  # Qdrant and Docling are endpoints the modules read at startup; have them
  # exist before the module pods come up.
  depends_on = [helm_release.qdrant, helm_release.docling_rq]
}

# Qdrant vector database (plausibility check, search, extraction). Upstream
# 0.3.0 expects an external endpoint (<qdrant-host>); the demo runs the
# official chart on its dedicated node pool, exactly as the 0.2.x upstream
# wrapper did (same chart version).
resource "helm_release" "qdrant" {
  name       = "qdrant"
  repository = "https://qdrant.github.io/qdrant-helm"
  chart      = "qdrant"
  version    = var.qdrant_chart_version
  namespace  = var.app_namespace

  timeout = 900
  wait    = false

  values = [yamlencode({
    replicaCount = 1
    image        = { pullPolicy = "IfNotPresent" }
    nodeSelector = { "spark-demo/pool" = "qdrant" }
    tolerations = [{
      key      = "dedicated"
      operator = "Equal"
      value    = "qdrant"
      effect   = "NoSchedule"
    }]
    persistence = {
      size             = "20Gi"
      storageClassName = "gp3"
    }
    resources = {
      requests = { cpu = "500m", memory = "2Gi" }
      limits   = { cpu = "2", memory = "6Gi" }
    }
  })]
}

# Docling (document parsing for the extraction module). Upstream 0.3.0 expects
# an external endpoint (<docling-host>); the demo keeps the 0.2.3 docling-rq
# chart (helm/docling-rq, vendored) with ElastiCache Valkey as the RQ broker.
resource "helm_release" "docling_rq" {
  name      = "${var.release_name}-docling"
  chart     = var.docling_chart_path
  namespace = var.app_namespace

  timeout = 900
  wait    = false

  values = [yamlencode({
    # Service and pods named <release>-docling-rq, the hostname the modules get.
    fullnameOverride = "${var.release_name}-docling-rq"
    image = {
      repository = var.gpu_enabled ? var.docling_gpu_image : var.docling_cpu_image
      tag        = var.docling_tag
      pullPolicy = "IfNotPresent"
    }
    docling = { device = var.gpu_enabled ? "cuda:0" : "cpu" }
    redisUrl = {
      secretName = "docling-rq-redis-url"
      key        = "uri"
    }
    worker = var.gpu_enabled ? local.docling_worker_gpu : local.docling_worker_cpu
  })]
}

locals {
  docling_worker_cpu = {
    replicaCount = 1
    device       = "cpu"
    nodeSelector = {}
    tolerations  = []
    resources = {
      requests = { cpu = "1", memory = "6Gi" }
      limits   = { cpu = "4", memory = "16Gi" }
    }
    extraEnv = []
  }
  docling_worker_gpu = {
    replicaCount = 1
    device       = "cuda:0"
    nodeSelector = { "spark-demo/pool" = "gpu" }
    tolerations  = [{ key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" }]
    resources = {
      requests = { cpu = "2", memory = "16Gi", "nvidia.com/gpu" = "1" }
      limits   = { cpu = "4", memory = "32Gi", "nvidia.com/gpu" = "1" }
    }
    extraEnv = [{ name = "LD_LIBRARY_PATH", value = "/usr/local/nvidia/lib64" }]
  }
}

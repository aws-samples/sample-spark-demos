# Deploys the unmodified upstream 00-spark-workflow umbrella chart from the
# git submodule, configured through the rendered demo overlay
# (helm/values/spark-workflow.demo.yaml.tftpl).
#
# dependency_update resolves the umbrella's file:// chart dependencies plus
# the one remote dependency (official Temporal chart) at apply time — the
# submodule stays untouched apart from Helm's charts/ build artifacts, which
# are ignored via .gitignore in this repo's working tree only.

locals {
  demo_values = templatefile(var.values_template_path, {
    frontend_host      = var.hosts.frontend
    keycloak_host      = var.hosts.keycloak
    temporal_host      = var.hosts.temporal
    keycloak_realm     = var.keycloak_realm
    keycloak_client_id = var.keycloak_client_id
    auth_mode          = var.auth_mode
    release_name       = var.release_name
    app_namespace      = var.app_namespace
    rds_host           = var.rds_host
    rds_port           = tostring(var.rds_port)
    s3_endpoint        = var.s3_endpoint_url
    region             = var.region
    bucket_dms         = var.bucket_names["dms"]
    bucket_temporal    = var.bucket_names["temporal_payloads"]
    bucket_archival    = var.bucket_names["temporal_archival"]
    bucket_quarantine  = var.bucket_names["quarantine"]
    litellm_url        = var.litellm_url
    vlm_model_name     = var.vlm_model_name
    docling_image      = var.gpu_enabled ? var.docling_gpu_image : var.docling_cpu_image
    docling_tag        = var.docling_tag
    docling_device     = var.gpu_enabled ? "cuda:0" : "cpu"
    valkey_enabled     = var.valkey_enabled
    gpu_enabled        = var.gpu_enabled
  })
}

resource "helm_release" "spark_workflow" {
  name      = var.release_name
  chart     = var.umbrella_chart_path
  namespace = var.app_namespace

  dependency_update = true
  timeout           = 1800
  # Umbrella spans ~107 resources incl. Temporal schema jobs; do not block
  # the apply on full readiness — the verify script checks convergence.
  wait = false

  # Documented upstream workarounds (see helm/postrender-spark-workflow.sh).
  postrender {
    binary_path = var.postrender_script_path
    args        = [var.gpu_enabled ? "gpu" : "cpu"]
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

  depends_on = [
    kubernetes_labels.default_sa_adoption,
    kubernetes_annotations.default_sa_adoption,
  ]
}

# Upstream wires its lookup-data seeds (project types, statuses, ...) only in
# the local process-compose setup — the Helm charts do not include them, so a
# fresh cluster starts with empty lookup tables (observed: the UI cannot load
# procedure types). This release runs the idempotent upstream seeds inside
# the running service pods after each umbrella change (same image, same env).
# Separate release because the umbrella installs with wait=false: its hooks
# would fire before the deployments are ready.
resource "helm_release" "seed_jobs" {
  name      = "${var.release_name}-seeds"
  chart     = var.seed_jobs_chart_path
  namespace = var.app_namespace

  # The hook job waits for the service rollouts (fresh installs pull images
  # and run migrations first), so give the release a generous timeout.
  timeout = 2700

  values = [
    yamlencode({
      enabled        = var.seed_jobs_enabled
      appReleaseName = var.release_name
      # Re-run the (idempotent) seeds whenever the umbrella config changes.
      runTrigger = substr(md5(local.demo_values), 0, 12)
    }),
  ]

  depends_on = [helm_release.spark_workflow]
}

# The upstream spicedb chart renders a ServiceAccount named "default" (to
# attach registry pull secrets). Kubernetes auto-creates that SA, so Helm
# refuses to install over it. Standard adoption: mark the existing SA as
# owned by this release BEFORE the umbrella installs — no upstream patch.
# Distinct field managers: both resources server-side-apply the same object;
# with the default shared manager the second patch would wipe the first one's
# fields (managed-field ownership is per manager, last write wins).
resource "kubernetes_labels" "default_sa_adoption" {
  api_version   = "v1"
  kind          = "ServiceAccount"
  field_manager = "tf-sa-adoption-labels"
  metadata {
    name      = "default"
    namespace = var.app_namespace
  }
  labels = {
    "app.kubernetes.io/managed-by" = "Helm"
  }
  force = true
}

resource "kubernetes_annotations" "default_sa_adoption" {
  api_version   = "v1"
  kind          = "ServiceAccount"
  field_manager = "tf-sa-adoption-annotations"
  metadata {
    name      = "default"
    namespace = var.app_namespace
  }
  annotations = {
    "meta.helm.sh/release-name"      = var.release_name
    "meta.helm.sh/release-namespace" = var.app_namespace
  }
  force = true
}

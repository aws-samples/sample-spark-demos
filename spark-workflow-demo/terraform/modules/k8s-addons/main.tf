# Cluster addons installed via Helm. Order matters:
#   1. Controllers (LBC, ESO, cert-manager, Envoy Gateway, external-dns)
#   2. CRD-based config (ClusterSecretStore, ClusterIssuer, Certificate,
#      GatewayClass/Gateway) via kubectl_manifest (applied after the CRDs exist)

# --- Namespaces ---------------------------------------------------------------

# Destroy-order guard (observed in the spark-api-demo destroy test): helm
# uninstall does NOT delete hook resources, so pre-install ExternalSecrets
# linger in the namespaces. Namespace deletion needs ESO alive to process
# their cleanup finalizer — without this edge terraform removed ESO first
# and the namespace hung until the provider timeout. depends_on ESO ⇒
# namespaces are deleted BEFORE the ESO release on destroy.
resource "kubernetes_namespace_v1" "platform" {
  metadata {
    name = var.platform_namespace
  }
  depends_on = [helm_release.external_secrets]
}

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace
  }
  depends_on = [helm_release.external_secrets]
}

# --- Storage: gp3 as default StorageClass -------------------------------------

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }
}

# De-default the pre-installed gp2 class so gp3 wins.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true
}

# --- Core controllers -----------------------------------------------------------

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version_aws_lb_controller
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  # The service mutator webhook intercepts every Service create with
  # failurePolicy=Fail and races against controller readiness during
  # bring-up (observed in both demos: 'failed calling webhook
  # mservice.elbv2.k8s.aws ... no endpoints available' while installing a
  # sibling addon). NLBs are driven via service annotations only.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  depends_on = [module.pod_identity_lb_controller]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_version_metrics_server
  namespace  = "kube-system"
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_version_external_secrets
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [module.pod_identity_external_secrets]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.chart_version_cert_manager
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
  # Pod Identity delivers credentials via the service account.
  set {
    name  = "serviceAccount.name"
    value = "cert-manager"
  }

  depends_on = [module.pod_identity_cert_manager]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.chart_version_external_dns
  namespace        = "external-dns"
  create_namespace = true

  values = [yamlencode({
    provider = { name = "aws" }
    env = [{
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }]
    domainFilters = [var.base_domain]
    policy        = "sync"
    txtOwnerId    = var.cluster_name
    # Watch Gateway API routes in addition to services/ingresses.
    sources = ["service", "ingress", "gateway-httproute"]
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
  })]

  depends_on = [module.pod_identity_external_dns]
}

resource "helm_release" "envoy_gateway" {
  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = var.chart_version_envoy_gateway
  namespace        = "envoy-gateway-system"
  create_namespace = true

  # Destroy-order guard: the Gateway's NLB is deleted by the AWS Load
  # Balancer Controller when the Envoy service goes away. Without this
  # edge, terraform destroy may remove the controller first and the NLB +
  # ENIs orphan, blocking the VPC teardown (cluster_config → Gateway CR →
  # Envoy service → NLB cleanup must all happen while the controller runs).
  depends_on = [helm_release.aws_load_balancer_controller]
}

# --- CRD-based configuration ------------------------------------------------------
# ClusterSecretStore, ClusterIssuer, Certificate, EnvoyProxy, GatewayClass and
# Gateway are installed through a local Helm chart. Rationale: the Terraform
# helm provider tolerates apply-time-unknown cluster credentials during plan,
# whereas kubectl-style providers fail ("no configuration has been provided")
# when the EKS endpoint is not known yet — which is always the case on the
# first single-pass apply.

# Destroy-time drain window between the Gateway CR deletion and the Envoy/
# LB-controller uninstalls. Unlike ingress-nginx (spark-api-demo), the
# Envoy SERVICE is owned by the Envoy Gateway controller, not by any helm
# release — deleting the Gateway CR only triggers the NLB cleanup
# asynchronously (observed: cluster_config gone after 1s, envoy_gateway +
# LB controller gone 2s later, NLB + its SGs orphaned and the IGW/subnet
# teardown deadlocked). 120s keeps both controllers alive long enough to
# deprovision the NLB and strip the service finalizer.
resource "time_sleep" "gateway_drain" {
  destroy_duration = "120s"

  depends_on = [
    helm_release.envoy_gateway,
    helm_release.aws_load_balancer_controller,
  ]
}

resource "helm_release" "cluster_config" {
  name      = "spark-cluster-config"
  chart     = var.cluster_config_chart_path
  namespace = var.platform_namespace

  # CRs only — nothing to wait for at the workload level.
  wait = false

  values = [yamlencode({
    region            = var.region
    route53ZoneId     = var.route53_zone_id
    acmeEmail         = var.acme_email
    platformNamespace = var.platform_namespace
    allowedCidrs      = var.allowed_cidrs
    certificate = {
      secretName = "spark-demo-tls"
      dnsNames = [
        var.frontend_fqdn,
        var.keycloak_fqdn,
        var.temporal_fqdn,
      ]
    }
  })]

  depends_on = [
    helm_release.external_secrets,
    helm_release.cert_manager,
    helm_release.envoy_gateway,
    kubernetes_namespace_v1.platform,
    # Destroy order: Gateway CR delete → 120s drain (NLB deprovision by the
    # still-alive controllers) → envoy/LBC uninstall.
    time_sleep.gateway_drain,
  ]
}

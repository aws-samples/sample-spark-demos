# Cluster addons installed via Helm. Differences from spark-workflow-demo:
# the upstream SPARK API charts expect `ingressClassName: nginx`, so the
# edge is ingress-nginx behind an NLB instead of Envoy Gateway; TLS comes
# from cert-manager's ingress-shim (cluster issuer annotation), DNS from
# external-dns watching Ingress resources.

# --- Namespaces ---------------------------------------------------------------

# Destroy-order guard (observed in the destroy test): the platform chart
# creates ExternalSecrets as pre-install HOOKS (rds-app/rds-master), and
# helm uninstall does NOT delete hook resources — they linger in the
# namespace. Namespace deletion then needs ESO alive to process their
# cleanup finalizer; without this edge terraform removed ESO first and the
# namespace hung until the provider timeout ("Some resources are
# remaining: externalsecrets... has 2 resource instances"). depends_on ESO
# ⇒ namespaces are deleted BEFORE the ESO release on destroy.
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
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = var.vpc_id
  }
  # The chart's service mutator webhook intercepts EVERY Service create in
  # the cluster with failurePolicy=Fail. During bring-up this races with
  # the controller pods becoming ready (observed on the from-zero
  # bootstrap: installing external-secrets failed with 'failed calling
  # webhook mservice.elbv2.k8s.aws ... no endpoints available'). The demo
  # drives the NLB purely via service annotations, so the mutator adds
  # nothing — disable it for a deterministic bootstrap.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
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
    sources       = ["service", "ingress"]
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
  })]

  depends_on = [module.pod_identity_external_dns]
}

# The edge: ingress-nginx fronted by an internet-facing NLB (ip targets via
# the AWS Load Balancer Controller). Upstream charts reference
# ingressClassName "nginx" — the chart's default class name.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.chart_version_ingress_nginx
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [yamlencode({
    controller = {
      service = {
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        }
        # Source restriction at L4: the LB controller turns this into the
        # ingress rules of the NLB's frontend security group, so it covers
        # every hostname and both listeners at once. Empty = open (the
        # from-zero default; nothing breaks for someone who has not set
        # DEMO_ALLOWED_CIDRS). An nginx-level allowlist would NOT work
        # here: with ip targets and use-proxy-protocol=false nginx never
        # sees the real client address.
        loadBalancerSourceRanges = var.allowed_cidrs
      }
      # The demo-inspector overlay is injected via a configuration-snippet
      # annotation (sub_filter on the frontend HTML) — snippets are off by
      # default and configuration-snippet is classified Critical.
      allowSnippetAnnotations = true
      config = {
        # Real client IPs for the services' access logs.
        use-proxy-protocol     = "false"
        annotations-risk-level = "Critical"
      }
    }
  })]

  depends_on = [helm_release.aws_load_balancer_controller]
}

# --- CRD-based configuration ------------------------------------------------------
# ClusterSecretStore + ClusterIssuer via a local chart (helm provider
# tolerates apply-time-unknown cluster credentials; kubectl-style providers
# do not — verified in the spark-workflow build).

resource "helm_release" "cluster_config" {
  name      = "spark-api-cluster-config"
  chart     = var.cluster_config_chart_path
  namespace = var.platform_namespace

  wait = false

  values = [yamlencode({
    region        = var.region
    route53ZoneId = var.route53_zone_id
    acmeEmail     = var.acme_email
  })]

  depends_on = [
    helm_release.external_secrets,
    helm_release.cert_manager,
    kubernetes_namespace_v1.platform,
  ]
}

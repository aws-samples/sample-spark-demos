# Pod Identity roles for all controllers (maintained policy presets from
# terraform-aws-modules/eks-pod-identity).

module "pod_identity_lb_controller" {
  # v1.12.1 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity.git?ref=9478c492d293927d658503fc26b0fec5a30e92bd"

  name = "${var.cluster_name}-lbc"

  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = var.tags
}

module "pod_identity_cert_manager" {
  # v1.12.1 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity.git?ref=9478c492d293927d658503fc26b0fec5a30e92bd"

  name = "${var.cluster_name}-cert-manager"

  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = "cert-manager"
      service_account = "cert-manager"
    }
  }

  tags = var.tags
}

module "pod_identity_external_dns" {
  # v1.12.1 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity.git?ref=9478c492d293927d658503fc26b0fec5a30e92bd"

  name = "${var.cluster_name}-external-dns"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = "external-dns"
      service_account = "external-dns"
    }
  }

  tags = var.tags
}

module "pod_identity_external_secrets" {
  # v1.12.1 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity.git?ref=9478c492d293927d658503fc26b0fec5a30e92bd"

  name = "${var.cluster_name}-eso"

  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = var.eso_secret_arns
  # Without this the module grants kms:Decrypt on EVERY key in the account.
  external_secrets_kms_key_arns      = var.eso_kms_key_arns
  external_secrets_create_permission = false

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }

  tags = var.tags
}

# LiteLLM calls Amazon Bedrock (gpt-oss-120b + Mistral Large for the
# structured-output check flows) with pod credentials. Cross-region
# inference profiles (eu.mistral.*) need BOTH the inference-profile ARN
# in the calling region AND the foundation-model ARNs in every region the
# profile may route to — scoped to the geography of bedrock_region
# (eu-central-1 → eu-*). Same pattern as the spark-workflow demo.
locals {
  bedrock_geo = split("-", var.bedrock_region)[0]
}

module "pod_identity_litellm" {
  # v1.12.1 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity.git?ref=9478c492d293927d658503fc26b0fec5a30e92bd"

  name = "${var.cluster_name}-litellm"

  attach_custom_policy = true
  policy_statements = [
    {
      sid     = "BedrockInvoke"
      actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      resources = [
        # On-demand models invoked directly in the configured region.
        "arn:aws:bedrock:${var.bedrock_region}::foundation-model/*",
        # Cross-region profile routing targets within the same geography.
        "arn:aws:bedrock:${local.bedrock_geo}-*::foundation-model/*",
        # The geo inference profiles themselves (account-scoped resources).
        "arn:aws:bedrock:${var.bedrock_region}:*:inference-profile/*",
      ]
    }
  ]

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = var.platform_namespace
      service_account = "litellm"
    }
  }

  tags = var.tags
}

# The demo inspector reads Bedrock invocation metrics from CloudWatch
# (read-only; the AWS-side proof next to the LiteLLM request log).
module "pod_identity_inspector" {
  # v1.12.1 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity.git?ref=9478c492d293927d658503fc26b0fec5a30e92bd"

  name = "${var.cluster_name}-demo-inspector"

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "CloudWatchRead"
      actions   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
      resources = ["*"]
    }
  ]

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = var.app_namespace
      service_account = "demo-inspector"
    }
  }

  tags = var.tags
}

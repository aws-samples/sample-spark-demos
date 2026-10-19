# EKS cluster with managed node groups. Upstream SPARK Workflow images are
# published amd64-only, therefore all node groups use x86 instances.
#
# Node layout (see design.md §6):
#   - default: services, Temporal, AI module workers
#   - qdrant:  dedicated + tainted (vector database)
#   - gpu:     optional (Docling CUDA), disabled by default

module "eks" {
  # v20.37.2 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=8a0efdbbc84180a26e0bacfd2b6fcfceac53b3b6"

  cluster_name    = var.name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Demo: public API endpoint so terraform/helm can run from a workstation.
  # Documented deviation from production (private endpoint + bastion/VPN).
  cluster_endpoint_public_access = true
  # Same allowlist as the NLB (DEMO_ALLOWED_CIDRS): when set, the operator's
  # own address must be in it or terraform/helm lose the API endpoint.
  cluster_endpoint_public_access_cidrs = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : ["0.0.0.0/0"]

  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
    aws-ebs-csi-driver     = {}
  }

  # The module's default node SG only opens ephemeral ports (>=1025)
  # between nodes; upstream services expose pod port 80, which Envoy
  # (running on other nodes) must reach.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node-to-node: all pod-to-pod traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"

    # ~30 container images across the stack: the 20 GiB default root volume
    # triggers node disk-pressure taints and pod evictions.
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = var.node_disk_size
          volume_type           = "gp3"
          delete_on_termination = true
        }
      }
    }
  }

  eks_managed_node_groups = merge(
    {
      default = {
        instance_types = [var.default_node_instance_type]
        min_size       = var.default_node_min
        max_size       = var.default_node_max
        desired_size   = var.default_node_desired

        labels = {
          "spark-demo/pool" = "default"
        }
      }
    },
    var.qdrant_node_count > 0 ? {
      qdrant = {
        instance_types = [var.qdrant_node_instance_type]
        min_size       = var.qdrant_node_count
        max_size       = var.qdrant_node_count
        desired_size   = var.qdrant_node_count

        # Single-AZ pin: Qdrant's PVCs are zonal EBS volumes. Without the
        # pin, any node replacement can move the pool to another AZ and
        # permanently strand the volumes (PV node-affinity mismatch).
        subnet_ids = [var.private_subnet_ids[var.qdrant_subnet_index]]

        labels = {
          "spark-demo/pool" = "qdrant"
        }
        taints = {
          dedicated = {
            key    = "dedicated"
            value  = "qdrant"
            effect = "NO_SCHEDULE"
          }
        }
      }
    } : {},
    var.gpu_enabled ? {
      gpu = {
        ami_type       = "AL2023_x86_64_NVIDIA"
        instance_types = [var.gpu_node_instance_type]
        min_size       = var.gpu_node_count
        max_size       = var.gpu_node_count
        desired_size   = var.gpu_node_count

        labels = {
          "spark-demo/pool" = "gpu"
        }
        taints = {
          gpu = {
            key    = "nvidia.com/gpu"
            value  = "true"
            effect = "NO_SCHEDULE"
          }
        }
      }
    } : {}
  )

  tags = var.tags
}

# EBS CSI driver needs AWS permissions; wire them via EKS Pod Identity.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  tags = var.tags
}

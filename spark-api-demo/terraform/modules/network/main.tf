# Demo VPC: 3 AZs, private subnets for EKS/RDS/ElastiCache, public subnets
# only for the NLB. Single NAT gateway keeps demo cost low (documented
# deviation from production HA).

# Zone identity is pinned by NAME (<region>a, <region>b, ...), so the subnet
# layout cannot shift when AWS adds an Availability Zone to the region
# (a sorted-and-sliced list would). Regions whose zone letters are not
# contiguous (e.g. only "a" and "c") set availability_zone_names explicitly.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name = "zone-name"
    values = length(var.availability_zone_names) > 0 ? var.availability_zone_names : [
      for i in range(var.az_count) : "${data.aws_region.current.name}${substr("abcdef", i, 1)}"
    ]
  }

  lifecycle {
    postcondition {
      condition     = length(self.names) == var.az_count
      error_message = "Expected ${var.az_count} available zones matching the zone-name filter; set availability_zone_names for this region."
    }
  }
}

locals {
  azs = sort(data.aws_availability_zones.available.names)

  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 240 + i)]
}

module "vpc" {
  # v5.21.0 — pinned to the commit the release tag points at (registry
  # version ranges resolve to whatever the tag points at tomorrow).
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=7c1f791efd61f326ed6102d564d1a65d1eceedf0"

  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet discovery tags for the AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

# Free gateway endpoint: keeps S3 traffic (images/artifacts/app data) off NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

data "aws_region" "current" {}

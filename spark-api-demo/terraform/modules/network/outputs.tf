output "vpc_id" {
  description = "ID of the demo VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR of the demo VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes, RDS, ElastiCache)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NLB only)."
  value       = module.vpc.public_subnets
}

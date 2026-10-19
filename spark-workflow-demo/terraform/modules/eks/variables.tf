variable "name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version of the EKS cluster."
  type        = string
  default     = "1.33"
}

variable "vpc_id" {
  description = "VPC the cluster is placed in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for nodes and control-plane ENIs."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Empty list = open (0.0.0.0/0, the module default) so a from-zero bring-up works without knowing the operator's IP."
  type        = list(string)
  default     = []
}

# --- Default node pool (application services, Temporal, AI modules) ---------
variable "default_node_instance_type" {
  description = "Instance type of the default node group (upstream images are amd64-only)."
  type        = string
  default     = "m6i.2xlarge"
}

variable "default_node_min" {
  description = "Minimum node count of the default node group."
  type        = number
  default     = 3
}

variable "default_node_max" {
  description = "Maximum node count of the default node group."
  type        = number
  default     = 5
}

variable "default_node_desired" {
  description = "Desired node count of the default node group."
  type        = number
  default     = 3
}

# --- Qdrant node pool (dedicated, tainted) -----------------------------------
variable "qdrant_node_instance_type" {
  description = "Instance type of the dedicated Qdrant node."
  type        = string
  default     = "r6i.xlarge"
}

variable "qdrant_node_count" {
  description = "Node count of the Qdrant node group (0 disables the pool; Qdrant then schedules on the default pool)."
  type        = number
  default     = 1
}

variable "qdrant_subnet_index" {
  description = "Index into private_subnet_ids pinning the Qdrant node group to ONE AZ. Qdrant PVs are zonal EBS volumes; a multi-AZ node group strands them whenever a node replacement lands in another AZ (observed live: FailedScheduling 'didn't match PersistentVolume's node affinity')."
  type        = number
  default     = 2
}

# --- Optional GPU node pool (Docling CUDA) ------------------------------------
variable "gpu_enabled" {
  description = "Provision a GPU node group (L4) for Docling CUDA mode."
  type        = bool
  default     = false
}

variable "gpu_node_instance_type" {
  description = "Instance type of the GPU node group."
  type        = string
  default     = "g6.xlarge"
}

variable "gpu_node_count" {
  description = "Node count of the GPU node group."
  type        = number
  default     = 1
}

variable "node_disk_size" {
  description = "Root volume size (GiB) of all node groups."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

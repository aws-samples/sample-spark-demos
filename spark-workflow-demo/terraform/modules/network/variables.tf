variable "name" {
  description = "Name prefix for all network resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the demo VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 3
}

variable "availability_zone_names" {
  description = "Explicit zone names to use (must have az_count entries). Empty = <region>a, <region>b, ... derived from az_count."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

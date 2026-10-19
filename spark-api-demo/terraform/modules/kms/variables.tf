variable "name" {
  description = "Alias name of the key (alias/<name>)."
  type        = string
}

variable "description" {
  description = "Human-readable key description."
  type        = string
  default     = "Customer-managed key for the demo environment (secrets, buckets, databases, logs)."
}

variable "cloudwatch_log_group_names" {
  description = "CloudWatch log group names (wildcards allowed, e.g. /aws/rds/instance/demo/*) that the CloudWatch Logs service may encrypt with this key. Empty disables the statement."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

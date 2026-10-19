# One customer-managed KMS key per demo environment. Replaces the AWS-managed
# default keys for everything the demo encrypts at rest (Secrets Manager
# entries, S3 buckets, RDS Performance Insights, ElastiCache, CloudWatch log
# groups) so that key usage is auditable per principal in CloudTrail and can
# be revoked centrally. The key policy keeps the account's IAM policies
# authoritative (root statement) and lets CloudWatch Logs use the key for
# exactly the log groups passed in.
#
# Demo lifecycle: 7-day deletion window (the minimum) so `make destroy`
# leaves no key hanging around for a month.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "key" {
  # This is a KMS *key policy*: "Resource = *" means "this key", and the
  # account-root statement is the AWS default that makes IAM policies
  # authoritative for key usage (without it nobody but the key policy's
  # principals could use the key). The IAM-policy checks below read it as
  # an identity policy with wildcard resources, which it is not.
  #checkov:skip=CKV_AWS_109: KMS key policy - Resource "*" is the key itself; root statement is the AWS default enabling IAM-based access control
  #checkov:skip=CKV_AWS_111: KMS key policy - Resource "*" is the key itself; write access is governed by IAM policies on the consuming principals
  #checkov:skip=CKV_AWS_356: KMS key policy - Resource "*" is the key itself (key policies cannot name another resource)
  # IAM policies in this account decide who may use the key.
  statement {
    sid       = "EnableIamUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts log groups with the key on behalf of the
  # services writing to them (CodeBuild, RDS). Scoped via the encryption
  # context to the log groups this environment creates. Built from names
  # (not resource references) so the key can exist before the log groups.
  dynamic "statement" {
    for_each = length(var.cloudwatch_log_group_names) > 0 ? [1] : []

    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"
      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
      }

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values = [
          for n in var.cloudwatch_log_group_names :
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${n}"
        ]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.key.json

  tags = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

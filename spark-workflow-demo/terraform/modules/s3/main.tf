# Object storage for SPARK Workflow. Upstream expects three S3-compatible
# buckets (see docker-compose minio-init): dms, temporal-payloads, quarantine.
# The application signs presigned URLs that the browser calls directly,
# therefore the dms bucket carries a CORS rule for the frontend origin.
#
# Access model (documented demo deviation): the app expects static
# S3_ACCESS_KEY_ID/S3_SECRET_ACCESS_KEY env vars, so a dedicated IAM user
# scoped to exactly these buckets is created. Production would prefer
# short-lived credentials via Pod Identity where the app supports it.
#
# At-rest protection: SSE-KMS with the environment's customer-managed key
# (S3 Bucket Keys keep the KMS call volume low), versioning with a short
# noncurrent-version expiry, and a lifecycle rule that aborts abandoned
# multipart uploads. Presigned URLs keep working unchanged — S3 applies the
# default encryption server-side, the signing principal (the IAM user below)
# holds the matching KMS permissions.

data "aws_caller_identity" "current" {}

locals {
  buckets = {
    dms               = "dms"
    temporal_payloads = "temporal-payloads"
    temporal_archival = "temporal-archival"
    quarantine        = "quarantine"
  }
  bucket_names = {
    for k, suffix in local.buckets :
    k => "${var.name}-${data.aws_caller_identity.current.account_id}-${suffix}"
  }
}

resource "aws_s3_bucket" "this" { # nosemgrep: aws-s3-bucket-versioning-not-enabled
  # ^ versioning is enabled via aws_s3_bucket_versioning.this below (provider v5 resource; the rule only knows the deprecated inline block)
  for_each = local.bucket_names

  # Server access logging would need a second (unencrypted-with-KMS) log
  # bucket and adds a destroy-time race on log delivery; the demo stores
  # synthetic documents only and relies on CloudTrail for the account.
  #checkov:skip=CKV_AWS_18: Demo buckets hold synthetic data; access logging would need an extra log bucket and complicates the hands-off destroy
  # Cross-region replication doubles storage for a single-region, short-lived demo.
  #checkov:skip=CKV_AWS_144: Single-region demo without a disaster-recovery requirement
  # Nothing consumes bucket events (the services poll via presigned URLs and
  # the API); a notification target without a consumer adds nothing.
  #checkov:skip=CKV2_AWS_62: No event consumer in the demo; notifications without a target add nothing
  bucket = each.value
  # Demo lifecycle: allow terraform destroy to remove non-empty buckets.
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Versioning keeps overwritten/deleted objects as noncurrent versions; for a
# demo they only need to survive long enough to undo a mistake. Abandoned
# multipart uploads (browser tab closed mid-upload) are cleaned up as well.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Browser-facing presigned uploads/downloads. With ClamAV enabled (the
# default) the DMS service issues presigned UPLOAD URLs against the
# quarantine bucket (user uploads pass the virus scan before being moved
# to dms), so BOTH buckets need the frontend-origin CORS rule — without it
# the browser blocks the direct PUT (observed: UI "Hochladen fehlgeschlagen",
# every upload failing).
resource "aws_s3_bucket_cors_configuration" "browser_facing" {
  for_each = { for k in ["dms", "quarantine"] : k => aws_s3_bucket.this[k].id }

  bucket = each.value

  cors_rule {
    allowed_origins = [var.frontend_origin]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# --- Application IAM user (static keys, demo-grade) --------------------------

resource "aws_iam_user" "app" {
  # The upstream services only speak "endpoint + static access keys" (MinIO
  # convention), so there is no role to assume — the user is the documented
  # demo deviation (README "Deviations", THREAT-MODEL 4.4/S).
  #checkov:skip=CKV_AWS_273: Upstream expects static S3 access keys (MinIO convention); documented demo deviation, scoped to the demo buckets
  name = "${var.name}-s3-app"
  tags = var.tags
}

resource "aws_iam_user_policy" "app" {
  # Inline policy on the single-purpose user — there is no group or role to
  # attach it to (see above); inline ties its lifetime to the user.
  #checkov:skip=CKV_AWS_40: Single-purpose demo user without a role to assume; the policy is scoped to the demo buckets and the KMS key
  name = "s3-app-buckets"
  user = aws_iam_user.app.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketLevel"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [for b in aws_s3_bucket.this : b.arn]
      },
      {
        Sid    = "ObjectLevel"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [for b in aws_s3_bucket.this : "${b.arn}/*"]
      },
      {
        # SSE-KMS: S3 calls KMS on behalf of the signing principal — PUT
        # (and presigned PUT from the browser) needs GenerateDataKey, GET
        # needs Decrypt, multipart completion needs both.
        Sid    = "BucketKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

resource "aws_iam_access_key" "app" {
  user = aws_iam_user.app.name
}

moved {
  from = aws_s3_bucket_cors_configuration.dms
  to   = aws_s3_bucket_cors_configuration.browser_facing["dms"]
}

# Image build infrastructure for SPARK API (design §4, ADR 0001):
# upstream publishes no container images, so this demo builds all service
# images itself.
#
#   local push script  ──git archive──►  S3 source bucket (versioned zip)
#                                            │ start-build-batch
#                                            ▼
#                                    CodeBuild batch (one build per image,
#                                    vendor-context transform, docker build,
#                                    push to ECR/<image>:<git-sha>)
#
# CodeConnections to gitlab.opencode.de is not possible, hence the S3
# source model. A CodePipeline trigger path stays a documented option
# (design decision 4); v1 triggers the batch directly from the push script.

locals {
  # services.txt is the single source of truth (image, context path, kind).
  service_lines = [
    for line in split("\n", file(var.services_file)) :
    trimspace(line)
    if trimspace(line) != "" && !startswith(trimspace(line), "#")
  ]
  services = {
    for line in local.service_lines :
    split(" ", line)[0] => {
      context = split(" ", line)[1]
      kind    = split(" ", line)[2]
    }
  }

  # Batch buildspec rendered from the same list: one build per image, all
  # sharing the source zip; per-build env selects context and buildspec.
  # Note: version must render as a YAML number — CodeBuild rejects "0.2"
  # as a string (observed: YAML_FILE_ERROR cannot unmarshal !!str).
  batch_buildspec = yamlencode({
    version = 0.2
    batch = {
      fast-fail = false
      build-graph = [
        for name, svc in local.services : {
          identifier = replace(name, "-", "_")
          env = merge(
            {
              variables = {
                IMAGE_NAME   = name
                SERVICE_PATH = svc.context
              }
            },
            # The frontend monorepo vite build (shell + 8 MFEs) OOMs on
            # MEDIUM (observed: npm exit 137 after ~3 min).
            svc.kind == "frontend" ? { compute-type = var.frontend_compute_type } : {}
          )
          buildspec = svc.kind == "frontend" ? "pipeline/buildspec-frontend.yml" : "pipeline/buildspec-service.yml"
        }
      ]
    }
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# --- Source bucket --------------------------------------------------------------

resource "aws_s3_bucket" "source" { # nosemgrep: aws-s3-bucket-versioning-not-enabled
  # ^ versioning is enabled via aws_s3_bucket_versioning.source below (provider v5 resource; the rule only knows the deprecated inline block)
  # Build inputs only (a git archive of public upstream source); access
  # logging would need a second log bucket and a destroy-time race on log
  # delivery — CloudTrail covers the account.
  #checkov:skip=CKV_AWS_18: Build-input bucket for public upstream source; access logging would need an extra log bucket and complicates the hands-off destroy
  # Cross-region replication of a re-creatable build archive adds nothing.
  #checkov:skip=CKV_AWS_144: Single-region demo; the archive is re-created by push-source.sh at any time
  # The push script starts the build batch explicitly; no event consumer.
  #checkov:skip=CKV2_AWS_62: No event consumer; push-source.sh starts the batch directly
  bucket        = "${var.name}-${data.aws_caller_identity.current.account_id}-source"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# The push script overwrites one object; CodeBuild reads the current
# version. Older versions only need to survive long enough to diagnose a
# broken build.
resource "aws_s3_bucket_lifecycle_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.source]
}

# --- ECR repositories (one per image) --------------------------------------------

# Tags are content-addressed (<source sha>-p<pipeline hash>, scripts/
# image-tag.sh) and IMMUTABLE: a tag can never be re-pointed at different
# content, so what was verified is what runs. The buildspecs skip an image
# whose tag already exists (same inputs = same content) instead of
# re-pushing it, and no floating `latest` is pushed any more.
resource "aws_ecr_repository" "this" {
  for_each = local.services

  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

# Keep the registry lean: retain only the most recent images per repo.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last ${var.ecr_keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_keep_images
      }
      action = { type = "expire" }
    }]
  })
}

# --- CodeBuild ---------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "build" {
  name              = "/codebuild/${var.name}-images"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_codebuild_project" "images" {
  # `docker build` inside CodeBuild needs the Docker daemon, which only runs
  # in privileged mode. The project holds no secrets (vendor-context
  # strategy), pushes only to its own repositories and reads only its own
  # source bucket — THREAT-MODEL 4.3 records the residual risk.
  #checkov:skip=CKV_AWS_316: Docker image builds require the privileged Docker daemon in CodeBuild; scoped role, no secrets in the build
  name           = "${var.name}-images"
  description    = "Builds all SPARK API images from the S3 source zip (batch)."
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.build_timeout_minutes
  encryption_key = var.kms_key_arn

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.source.bucket}/${var.source_object_key}"
    buildspec = local.batch_buildspec
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = var.compute_type
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # docker build

    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
    }
    environment_variable {
      name  = "ECR_PREFIX"
      value = var.name
    }
  }

  build_batch_config {
    service_role = aws_iam_role.codebuild.arn
    restrictions {
      maximum_builds_allowed = length(local.services) + 5
      compute_types_allowed  = []
    }
    timeout_in_mins = var.batch_timeout_minutes
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  tags = var.tags
}

# --- IAM ---------------------------------------------------------------------------

resource "aws_iam_role" "codebuild" {
  name = "${var.name}-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# Everything resource-scoped lives here; the one action that has no
# resource-level permissions (ecr:GetAuthorizationToken) sits in its own
# policy below so no wildcard shares a statement list with data access.
resource "aws_iam_role_policy" "codebuild" {
  name = "build-images"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.build.arn}:*"
      },
      {
        Sid      = "SourceRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketVersioning", "s3:ListBucket"]
        Resource = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]
      },
      {
        # The source zip is SSE-KMS encrypted (bucket default); CodeBuild
        # decrypts it with this key and encrypts build data with it.
        Sid      = "SourceKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          # tag-exists check before building (immutable tags)
          "ecr:DescribeImages"
        ]
        Resource = [for r in aws_ecr_repository.this : r.arn]
      },
      {
        Sid    = "BatchSelfOrchestration"
        Effect = "Allow"
        Action = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:RetryBuild"]
        # The batch service role starts the member builds of this project.
        Resource = "arn:${data.aws_partition.current.partition}:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/${var.name}-images"
      }
    ]
  })
}

# ecr:GetAuthorizationToken returns a registry login token for the whole
# account registry and supports no resource-level scoping — the only "*"
# resource in this module, kept alone in its own policy.
resource "aws_iam_role_policy" "codebuild_ecr_auth" {
  name = "ecr-auth"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcrAuth"
        Effect = "Allow"
        # nosemgrep: no-iam-creds-exposure
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      }
    ]
  })
}

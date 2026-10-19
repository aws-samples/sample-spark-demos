# Central secret generation. Terraform generates every credential, stores it
# in AWS Secrets Manager, and the External Secrets Operator syncs them into
# Kubernetes Secrets with the names the demo umbrella expects.
#
# recovery_window_in_days = 0 → demo teardown deletes secrets immediately.
#
# Scope note (v1): SPARK API has no Keycloak/SpiceDB/Temporal in scope —
# the secret set is RDS, RabbitMQ, Neo4j, LiteLLM, and the S3 app user.
# Extend here when the umbrella wiring matrix (spec task 4.2) surfaces
# additional credentials.

# --- Random values ------------------------------------------------------------

resource "random_password" "rds_master" {
  length  = 32
  special = false
}

# One application DB user for all service databases (demo pragmatism,
# same decision as spark-workflow-demo; production would use per-service
# users).
resource "random_password" "rds_app" {
  length  = 32
  special = false
}

resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

resource "random_password" "neo4j" {
  length  = 24
  special = false
}

resource "random_password" "litellm_master_key" {
  length  = 40
  special = false
}

# HMAC signing key for the bizlog audit-safe logger. AuditSafeLogger raises
# at construction when BIZLOG_AUDIT_SIGNING_KEY is empty — even with audit
# logging disabled (observed: kommentar-service crashloop "Audit-safe
# logging requires a signing key" because it builds the logger at import
# time).
resource "random_password" "bizlog_signing_key" {
  length  = 48
  special = false
}

# Auth perimeter (Keycloak + oauth2-proxy). SPARK API v0.4.x ships no auth
# — upstream delegates it to the demosplan platform (outside demo scope),
# so the demo puts an OSS OIDC perimeter in front of the ingress.
resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "random_password" "keycloak_client_secret" {
  length  = 40
  special = false
}

resource "random_password" "keycloak_demo_user" {
  length  = 16
  special = false
}

# oauth2-proxy requires a cookie secret of exactly 16/24/32 bytes.
resource "random_password" "oauth2_cookie_secret" {
  length  = 32
  special = false
}

# --- Secrets Manager entries ----------------------------------------------------

resource "aws_secretsmanager_secret" "rds_master" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/rds/master"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = var.rds_master_username
    password = random_password.rds_master.result
    host     = var.rds_host
    port     = var.rds_port
  })
}

resource "aws_secretsmanager_secret" "rds_app" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/rds/app"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_app" {
  secret_id = aws_secretsmanager_secret.rds_app.id
  secret_string = jsonencode({
    username = "spark_app"
    password = random_password.rds_app.result
    host     = var.rds_host
    port     = var.rds_port
  })
}

# In-cluster RabbitMQ (RabbitMQ Cluster Operator). The bizlog shared lib
# connects with pika WITHOUT credential/TLS options, so the broker gets a
# permissive demo user on a cluster-internal listener; AMQP_URL-based
# services use these credentials.
resource "aws_secretsmanager_secret" "rabbitmq" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/rabbitmq"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "rabbitmq" {
  secret_id = aws_secretsmanager_secret.rabbitmq.id
  secret_string = jsonencode({
    username = "spark"
    password = random_password.rabbitmq.result
    # Ready-made broker URL: several services consume RABBITMQ_URL/AMQP_URL
    # as one value (aio_pika/pika URL style).
    url = "amqp://spark:${random_password.rabbitmq.result}@rabbitmq.${var.platform_namespace}.svc.cluster.local:5672/%2f"
  })
}

resource "aws_secretsmanager_secret" "neo4j" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/neo4j"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "neo4j" {
  secret_id = aws_secretsmanager_secret.neo4j.id
  secret_string = jsonencode({
    username = "neo4j"
    password = random_password.neo4j.result
  })
}

resource "aws_secretsmanager_secret" "litellm" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/llm/litellm"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "litellm" {
  secret_id = aws_secretsmanager_secret.litellm.id
  secret_string = jsonencode({
    master_key = random_password.litellm_master_key.result
  })
}

resource "aws_secretsmanager_secret" "bizlog" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/bizlog"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "bizlog" {
  secret_id = aws_secretsmanager_secret.bizlog.id
  secret_string = jsonencode({
    signing_key = random_password.bizlog_signing_key.result
  })
}

resource "aws_secretsmanager_secret" "keycloak" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/auth/keycloak"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "keycloak" {
  secret_id = aws_secretsmanager_secret.keycloak.id
  secret_string = jsonencode({
    admin_password     = random_password.keycloak_admin.result
    client_id          = var.keycloak_client_id
    client_secret      = random_password.keycloak_client_secret.result
    demo_user_email    = var.keycloak_demo_user_email
    demo_user_password = random_password.keycloak_demo_user.result
    token_url          = "https://${var.auth_host}/realms/${var.keycloak_realm}/protocol/openid-connect/token"
  })
}

resource "aws_secretsmanager_secret" "oauth2_proxy" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/auth/oauth2-proxy"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "oauth2_proxy" {
  secret_id = aws_secretsmanager_secret.oauth2_proxy.id
  secret_string = jsonencode({
    cookie_secret = random_password.oauth2_cookie_secret.result
  })
}

resource "aws_secretsmanager_secret" "s3_app" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/s3/app"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "s3_app" {
  secret_id = aws_secretsmanager_secret.s3_app.id
  secret_string = jsonencode(merge(
    {
      access_key_id     = var.s3_access_key_id
      secret_access_key = var.s3_secret_access_key
      endpoint_url      = var.s3_endpoint_url
      region            = var.s3_region
    },
    { for k, v in var.s3_bucket_names : "bucket_${k}" => v }
  ))
}

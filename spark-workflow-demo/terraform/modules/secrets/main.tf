# Central secret generation. Terraform generates every credential, stores it
# in AWS Secrets Manager, and the External Secrets Operator syncs them into
# Kubernetes Secrets with the names the upstream charts expect.
#
# recovery_window_in_days = 0 → demo teardown deletes secrets immediately.

locals {
  # Dedicated PostgreSQL users created by the DB init job.
  db_users = ["app", "temporal", "keycloak", "spicedb"]
}

# --- Random values ------------------------------------------------------------

resource "random_password" "rds_master" {
  length  = 32
  special = false
}

resource "random_password" "db_user" {
  for_each = toset(local.db_users)

  length  = 32
  special = false
}

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

resource "random_password" "spicedb_preshared_key" {
  length  = 40
  special = false
}

resource "random_password" "litellm_master_key" {
  length  = 40
  special = false
}

# oauth2-proxy requires a cookie secret of exactly 16/24/32 bytes.
resource "random_password" "oauth2_cookie_secret" {
  length  = 32
  special = false
}

# ElastiCache AUTH token: 16-128 chars, no '/', '"', '@' or spaces.
resource "random_password" "valkey_auth_token" {
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

resource "aws_secretsmanager_secret" "db_user" {
  for_each = toset(local.db_users)

  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/rds/${each.key}"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_user" {
  for_each = toset(local.db_users)

  secret_id = aws_secretsmanager_secret.db_user[each.key].id
  secret_string = jsonencode(merge(
    {
      username = "spark_${each.key}"
      password = random_password.db_user[each.key].result
      host     = var.rds_host
      port     = var.rds_port
    },
    # SpiceDB consumes a ready-made DSN (spicedb-config secret, key datastore_uri).
    each.key == "spicedb" ? {
      datastore_uri = "postgres://spark_spicedb:${random_password.db_user["spicedb"].result}@${var.rds_host}:${var.rds_port}/spicedb"
    } : {}
  ))
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
  secret_string = jsonencode({
    access_key_id     = var.s3_access_key_id
    secret_access_key = var.s3_secret_access_key
    endpoint_url      = var.s3_endpoint_url
    region            = var.s3_region
    bucket_dms        = var.s3_bucket_names["dms"]
    bucket_temporal   = var.s3_bucket_names["temporal_payloads"]
    bucket_quarantine = var.s3_bucket_names["quarantine"]
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
    token_url          = "https://${var.keycloak_host}/realms/${var.keycloak_realm}/protocol/openid-connect/token"
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

resource "aws_secretsmanager_secret" "spicedb" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/auth/spicedb"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "spicedb" {
  secret_id = aws_secretsmanager_secret.spicedb.id
  secret_string = jsonencode({
    preshared_key = random_password.spicedb_preshared_key.result
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
    # Bearer token for the EXTERNAL prompt-injection guard endpoint
    # (INJECTION_MODEL_URL, not deployed in the demo). The module only
    # validates non-emptiness (env.py min_length=1); the public HF model
    # download is anonymous and independent of this value.
    # checkov:skip=CKV_SECRET_6: Literal placeholder for an endpoint the demo does not deploy, not a credential
    injection_model_token = "demo-placeholder"
  })
}

resource "aws_secretsmanager_secret" "valkey" {
  count = var.valkey_url != null ? 1 : 0

  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/valkey"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "valkey" {
  count = var.valkey_url != null ? 1 : 0

  secret_id = aws_secretsmanager_secret.valkey[0].id
  secret_string = jsonencode({
    uri = var.valkey_url
  })
}

# FPP portal integration credentials. The demo has no Fachplanungsportal
# connection — placeholder values keep the services bootable; the FPP
# integration flows are documented as out of demo scope.
resource "aws_secretsmanager_secret" "fpp" {
  # Rotation would need a rotation Lambda per credential AND consumers that
  # re-read it; the demo services receive these values once via ESO as
  # static environment variables (documented demo deviation).
  #checkov:skip=CKV2_AWS_57: Static demo credentials consumed via ESO - rotation would invalidate running services
  name                    = "${var.name}/integrations/fpp"
  recovery_window_in_days = 0
  kms_key_id              = var.kms_key_arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "fpp" {
  secret_id = aws_secretsmanager_secret.fpp.id
  secret_string = jsonencode({
    oidc_client_id     = "fpp-demo-placeholder"
    oidc_client_secret = random_password.fpp_placeholder.result
    oidc_user          = "fpp-demo-user"
    oidc_password      = random_password.fpp_placeholder.result
    oidc_token_url     = "https://${var.keycloak_host}/realms/${var.keycloak_realm}/protocol/openid-connect/token"
  })
}

resource "random_password" "fpp_placeholder" {
  length  = 24
  special = false
}

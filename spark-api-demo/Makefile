# =============================================================================
# spark-api-demo — deployment entry point
# =============================================================================
# Reads the central, untracked root .env (../.env) and maps it to Terraform
# variables (TF_VAR_*). No account IDs/zones/profiles in Git.
#
#   make init      # terraform init
#   make plan      # terraform plan
#   make apply     # terraform apply (bring up the demo)
#   make bootstrap # FROM ZERO: infra -> image builds (blocking) -> workloads
#   make destroy   # tear the demo down completely
#   make validate  # fmt-check + validate (no AWS access)
#   make outputs   # show the important URLs/endpoints
# =============================================================================

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
ENV_FILE := $(ROOT_DIR)/.env
TF_DIR   := terraform/envs/demo

ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
else
$(warning [spark-api-demo] $(ENV_FILE) not found - run 'cp .env.example .env' in the repo root)
endif

# --- .env → TF_VAR mapping ----------------------------------------------------
export TF_VAR_aws_region      := $(AWS_REGION)
export TF_VAR_bedrock_region  := $(BEDROCK_REGION)
export TF_VAR_route53_zone_id := $(ROUTE53_ZONE_ID)
export TF_VAR_base_domain     := $(BASE_DOMAIN)
export TF_VAR_acme_email      := $(ACME_EMAIL)
export TF_VAR_api_host        := $(SPARK_API_HOST)

# Note: apply/destroy can run >15 min. The providers' EKS tokens expire
# after 15 min; on "Unauthorized" mid-apply, first renew the AWS CLI
# session (e.g. `aws sso login` or fresh short-lived credentials for
# AWS_PROFILE) and re-run the same command — all steps are idempotent.

# Deploy images by the build-input tag (submodule sha + pipeline hash,
# exactly what the build batch pushes — see scripts/image-tag.sh) instead
# of a floating :latest. Override with SPARK_API_IMAGE_TAG for a specific
# older build.
ifndef SPARK_API_IMAGE_TAG
SPARK_API_IMAGE_TAG := $(shell ./scripts/image-tag.sh 2>/dev/null)
endif
ifneq ($(strip $(SPARK_API_IMAGE_TAG)),)
export TF_VAR_image_tag := $(SPARK_API_IMAGE_TAG)
else ifneq ($(filter plan apply bootstrap,$(MAKECMDGOALS)),)
# The registry holds content tags only (IMMUTABLE repositories, no :latest
# is pushed), so a deploy without a resolvable tag would roll every
# deployment onto an image that does not exist. Fail the deploying targets
# instead; destroy/validate/outputs do not need a tag.
$(error image tag unresolved: scripts/image-tag.sh failed (submodule checked out?) and SPARK_API_IMAGE_TAG is unset)
endif

# Optional overrides — only exported when set in .env
ifdef SPARK_API_PROJECT_PREFIX
export TF_VAR_project_prefix := $(SPARK_API_PROJECT_PREFIX)
endif
ifdef SPARK_API_NODE_INSTANCE_TYPE
export TF_VAR_node_instance_type := $(SPARK_API_NODE_INSTANCE_TYPE)
endif
ifdef SPARK_API_NODE_COUNT
export TF_VAR_node_count := $(SPARK_API_NODE_COUNT)
endif
ifdef SPARK_API_STATEFUL_NODE_COUNT
export TF_VAR_stateful_node_count := $(SPARK_API_STATEFUL_NODE_COUNT)
endif
ifdef SPARK_API_RDS_INSTANCE_CLASS
export TF_VAR_rds_instance_class := $(SPARK_API_RDS_INSTANCE_CLASS)
endif
ifdef SPARK_API_RDS_DELETION_PROTECTION
export TF_VAR_rds_deletion_protection := $(SPARK_API_RDS_DELETION_PROTECTION)
endif
ifdef SPARK_API_AUTH_HOST
export TF_VAR_auth_host := $(SPARK_API_AUTH_HOST)
endif
ifdef SPARK_API_AUTH_ENABLED
export TF_VAR_auth_enabled := $(SPARK_API_AUTH_ENABLED)
endif
# Shared with spark-workflow-demo: optional corporate OIDC provider in front
# of every page (empty = disabled, Keycloak demo login as before).
ifdef EXTERNAL_OIDC_ISSUER_URL
export TF_VAR_external_oidc_issuer_url    := $(EXTERNAL_OIDC_ISSUER_URL)
export TF_VAR_external_oidc_client_id     := $(EXTERNAL_OIDC_CLIENT_ID)
export TF_VAR_external_oidc_client_secret := $(EXTERNAL_OIDC_CLIENT_SECRET)
endif
# Shared with spark-workflow-demo: one CIDR set gates both demos' NLBs.
ifdef DEMO_ALLOWED_CIDRS
export TF_VAR_allowed_cidrs := $(DEMO_ALLOWED_CIDRS)
endif

.PHONY: init plan apply bootstrap destroy validate fmt outputs check-env

check-env:
	@test -n "$(AWS_REGION)"      || (echo "AWS_REGION missing in .env" && exit 1)
	@test -n "$(ROUTE53_ZONE_ID)" || (echo "ROUTE53_ZONE_ID missing in .env" && exit 1)
	@test -n "$(BASE_DOMAIN)"     || (echo "BASE_DOMAIN missing in .env" && exit 1)
	@test -n "$(ACME_EMAIL)"      || (echo "ACME_EMAIL missing in .env" && exit 1)
	@test -n "$(SPARK_API_HOST)"  || (echo "SPARK_API_HOST missing in .env" && exit 1)

init: check-env
	terraform -chdir=$(TF_DIR) init

plan: check-env
	terraform -chdir=$(TF_DIR) plan

apply: check-env
	terraform -chdir=$(TF_DIR) apply

# From-zero bring-up. A plain `make apply` on an empty account would roll
# the workloads before any image exists in ECR (hook jobs fail at
# ImagePullBackOff) — bootstrap orders it: infra first (targeted apply,
# expected-warning about -target), then the source push + build batch
# (blocking), then the full apply that rolls the workloads.
bootstrap: check-env
	terraform -chdir=$(TF_DIR) init -input=false
	terraform -chdir=$(TF_DIR) apply \
	  -target=module.network -target=module.eks -target=module.secrets \
	  -target=module.rds -target=module.s3 -target=module.registry_build \
	  -target=module.k8s_addons
	./scripts/push-source.sh --wait
	terraform -chdir=$(TF_DIR) apply

destroy: check-env
	terraform -chdir=$(TF_DIR) destroy

fmt:
	terraform fmt -recursive terraform

validate:
	terraform fmt -check -recursive terraform
	terraform -chdir=$(TF_DIR) init -backend=false -input=false > /dev/null
	terraform -chdir=$(TF_DIR) validate

outputs:
	terraform -chdir=$(TF_DIR) output

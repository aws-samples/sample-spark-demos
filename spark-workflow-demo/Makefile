# =============================================================================
# spark-workflow-demo — deployment entry point
# =============================================================================
# Reads the central, untracked root .env (../.env) and maps it to Terraform
# variables (TF_VAR_*). No account IDs/zones/profiles in Git.
#
#   make init      # terraform init
#   make plan      # terraform plan
#   make apply     # terraform apply (bring up the demo)
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
$(warning [spark-workflow-demo] $(ENV_FILE) not found - run 'cp .env.example .env' in the repo root)
endif

# --- .env → TF_VAR mapping ----------------------------------------------------
export TF_VAR_aws_region      := $(AWS_REGION)
export TF_VAR_bedrock_region  := $(BEDROCK_REGION)
export TF_VAR_project_prefix  := $(PROJECT_PREFIX)
export TF_VAR_route53_zone_id := $(ROUTE53_ZONE_ID)
export TF_VAR_base_domain     := $(BASE_DOMAIN)
export TF_VAR_acme_email      := $(ACME_EMAIL)
export TF_VAR_workflow_host   := $(SPARK_WORKFLOW_HOST)
export TF_VAR_keycloak_host   := $(SPARK_WORKFLOW_KEYCLOAK_HOST)
export TF_VAR_temporal_host   := $(SPARK_WORKFLOW_TEMPORAL_HOST)
export TF_VAR_demo_user_email := $(SPARK_WORKFLOW_DEMO_USER_EMAIL)

# Note: apply/destroy can run >15 min (node group rollouts, Helm upgrades
# across ~20 deployments). The providers' EKS tokens expire after 15 min;
# on "Unauthorized" mid-apply, first renew the AWS CLI session (e.g.
# `aws sso login` or fresh short-lived credentials for AWS_PROFILE) and
# re-run the same command — all steps are idempotent.

# Optional overrides — only exported when set in .env
ifdef SPARK_WORKFLOW_GPU_ENABLED
export TF_VAR_gpu_enabled := $(SPARK_WORKFLOW_GPU_ENABLED)
endif
ifdef SPARK_WORKFLOW_VALKEY_ENABLED
export TF_VAR_valkey_enabled := $(SPARK_WORKFLOW_VALKEY_ENABLED)
endif
ifdef BEDROCK_VLM_MODEL_ID
export TF_VAR_bedrock_vlm_model_id := $(BEDROCK_VLM_MODEL_ID)
endif
ifdef SPARK_WORKFLOW_SEED_JOBS_ENABLED
export TF_VAR_seed_jobs_enabled := $(SPARK_WORKFLOW_SEED_JOBS_ENABLED)
endif
ifdef SPARK_WORKFLOW_NODE_INSTANCE_TYPE
export TF_VAR_node_instance_type := $(SPARK_WORKFLOW_NODE_INSTANCE_TYPE)
endif
ifdef SPARK_WORKFLOW_NODE_COUNT
export TF_VAR_node_count := $(SPARK_WORKFLOW_NODE_COUNT)
endif
ifdef SPARK_WORKFLOW_RDS_INSTANCE_CLASS
export TF_VAR_rds_instance_class := $(SPARK_WORKFLOW_RDS_INSTANCE_CLASS)
endif
ifdef SPARK_WORKFLOW_RDS_DELETION_PROTECTION
export TF_VAR_rds_deletion_protection := $(SPARK_WORKFLOW_RDS_DELETION_PROTECTION)
endif
# Shared with spark-api-demo: one CIDR set gates both demos' NLBs.
ifdef DEMO_ALLOWED_CIDRS
export TF_VAR_allowed_cidrs := $(DEMO_ALLOWED_CIDRS)
endif
# Shared with spark-api-demo: optional corporate OIDC provider in front of
# every page (empty = disabled, Keycloak demo login as before).
ifdef EXTERNAL_OIDC_ISSUER_URL
export TF_VAR_external_oidc_issuer_url    := $(EXTERNAL_OIDC_ISSUER_URL)
export TF_VAR_external_oidc_client_id     := $(EXTERNAL_OIDC_CLIENT_ID)
export TF_VAR_external_oidc_client_secret := $(EXTERNAL_OIDC_CLIENT_SECRET)
endif

.PHONY: init plan apply destroy validate fmt outputs check-env stage-charts

check-env:
	@test -n "$(AWS_REGION)"      || (echo "AWS_REGION missing in .env" && exit 1)
	@test -n "$(ROUTE53_ZONE_ID)" || (echo "ROUTE53_ZONE_ID missing in .env" && exit 1)
	@test -n "$(BASE_DOMAIN)"     || (echo "BASE_DOMAIN missing in .env" && exit 1)
	@test -n "$(ACME_EMAIL)"      || (echo "ACME_EMAIL missing in .env" && exit 1)

# Copies the upstream charts out of the (unmodified) submodule into a
# gitignored build directory so `helm dependency update` does not dirty
# the submodule.
stage-charts:
	rm -rf .build/spark-workflow-charts
	mkdir -p .build
	cp -R spark-workflow/helm/charts .build/spark-workflow-charts

init: check-env
	terraform -chdir=$(TF_DIR) init

plan: check-env stage-charts
	terraform -chdir=$(TF_DIR) plan

apply: check-env stage-charts
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

#!/usr/bin/env bash
# =============================================================================
# push-source.sh — ship the upstream source to S3 and trigger the image builds
# =============================================================================
# Creates a deterministic source archive from the spark-api submodule HEAD
# (git archive), overlays the demo pipeline files (buildspecs, context
# transform, base image map) plus a SOURCE_VERSION stamp, uploads it to the
# versioned S3 source bucket, and starts the CodeBuild batch.
#
# Idempotent: if the zip content hash matches what is already in S3, the
# upload (and optionally the build) is skipped.
#
# Usage:
#   scripts/push-source.sh [--dry-run] [--no-build] [--force] [--wait]
#
#   --dry-run   show what would happen, change nothing
#   --no-build  upload only, do not start the build batch
#   --force     upload + build even if the source is unchanged
#   --wait      block until the build batch finishes (exit 1 on failure)
# =============================================================================
set -euo pipefail

C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s ✔ %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s ⚠ %s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
die()  { printf '%s ✘ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

DRY_RUN=false; NO_BUILD=false; FORCE=false; WAIT=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-build) NO_BUILD=true ;;
    --force) FORCE=true ;;
    --wait) WAIT=true ;;
    *) die "unknown flag: $arg" ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
SUBMODULE="$PROJECT_DIR/spark-api"
TF_DIR="$PROJECT_DIR/terraform/envs/demo"

# shellcheck disable=SC1091
[ -f "$ROOT_DIR/.env" ] && set -a && source "$ROOT_DIR/.env" && set +a

command -v git >/dev/null || die "git not found"
command -v aws >/dev/null || die "aws CLI not found"
command -v zip >/dev/null || die "zip not found"

# --- Resolve targets from terraform outputs ------------------------------------
say "Resolving build infrastructure from terraform outputs"
SOURCE_BUCKET=$(terraform -chdir="$TF_DIR" output -raw source_bucket 2>/dev/null) || die "terraform output source_bucket failed — did 'make apply' run?"
CODEBUILD_PROJECT=$(terraform -chdir="$TF_DIR" output -raw codebuild_project 2>/dev/null) || die "terraform output codebuild_project failed"
OBJECT_KEY="source/spark-api-source.zip"
ok "bucket s3://${SOURCE_BUCKET}, project ${CODEBUILD_PROJECT}"

# --- Build the archive -----------------------------------------------------------
GIT_SHA=$(git -C "$SUBMODULE" rev-parse HEAD)
GIT_SHORT=$(git -C "$SUBMODULE" rev-parse --short HEAD)
# Image tag = source sha + pipeline hash (see scripts/image-tag.sh).
IMAGE_TAG=$("$PROJECT_DIR/scripts/image-tag.sh")
DIRTY=$(git -C "$SUBMODULE" status --porcelain | wc -l | tr -d ' ')
[ "$DIRTY" = "0" ] || die "submodule has local modifications — it must stay pristine"

WORKDIR=$(mktemp -d); trap 'rm -rf "$WORKDIR"' EXIT
ZIP="$WORKDIR/spark-api-source.zip"

say "Archiving submodule HEAD ${C_BOLD}${GIT_SHORT}${C_OFF} (git archive, deterministic)"
git -C "$SUBMODULE" archive --format=zip -o "$ZIP" HEAD

say "Overlaying demo pipeline files + inspector + SOURCE_VERSION"
(
  cd "$WORKDIR"
  mkdir -p overlay/pipeline
  cp "$PROJECT_DIR"/pipeline/prepare-context.sh \
     "$PROJECT_DIR"/pipeline/base-image-map.env \
     "$PROJECT_DIR"/pipeline/buildspec-service.yml \
     "$PROJECT_DIR"/pipeline/buildspec-frontend.yml \
     overlay/pipeline/
  # Demo tooling built alongside the upstream images (services.txt entry
  # demo-inspector); lives in this repo, not in the submodule.
  cp -R "$PROJECT_DIR"/inspector overlay/inspector
  printf '%s\n' "$IMAGE_TAG" > overlay/SOURCE_VERSION
  cd overlay && zip -q -X "$ZIP" -r .
)

LOCAL_MD5=$(md5 -q "$ZIP" 2>/dev/null || md5sum "$ZIP" | cut -d' ' -f1)
SIZE=$(du -h "$ZIP" | cut -f1 | tr -d ' ')
ok "archive ready: ${SIZE}, md5 ${LOCAL_MD5}, image tag ${IMAGE_TAG}"

# --- Idempotency check ------------------------------------------------------------
REMOTE_MD5=$(aws s3api head-object --bucket "$SOURCE_BUCKET" --key "$OBJECT_KEY" \
  --query 'Metadata.md5' --output text 2>/dev/null || echo "none")

if [ "$REMOTE_MD5" = "$LOCAL_MD5" ] && ! "$FORCE"; then
  ok "S3 already has this exact source (md5 match) — nothing to upload"
  "$NO_BUILD" || warn "skipping build trigger too (use --force to rebuild the same source)"
  exit 0
fi

if "$DRY_RUN"; then
  warn "dry-run: would upload ${SIZE} to s3://${SOURCE_BUCKET}/${OBJECT_KEY} (remote md5: ${REMOTE_MD5})"
  "$NO_BUILD" || warn "dry-run: would start build batch on ${CODEBUILD_PROJECT}"
  exit 0
fi

# --- Upload -----------------------------------------------------------------------
say "Uploading to s3://${SOURCE_BUCKET}/${OBJECT_KEY}"
aws s3api put-object \
  --bucket "$SOURCE_BUCKET" --key "$OBJECT_KEY" \
  --body "$ZIP" \
  --metadata "md5=${LOCAL_MD5},git_sha=${GIT_SHA}" > /dev/null
ok "uploaded (git ${GIT_SHORT})"

# --- Trigger the batch --------------------------------------------------------------
if "$NO_BUILD"; then
  warn "--no-build: skipping the build batch"
  exit 0
fi

say "Starting CodeBuild batch on ${CODEBUILD_PROJECT}"
BATCH_ID=$(aws codebuild start-build-batch \
  --project-name "$CODEBUILD_PROJECT" \
  --query 'buildBatch.id' --output text)
ok "batch started: ${BATCH_ID}"
printf '\nWatch it:\n  aws codebuild batch-get-build-batches --ids %s --query '\''buildBatches[0].buildGroups[].{id:identifier,status:currentBuildSummary.buildStatus}'\'' --output table\n' "$BATCH_ID"

# --- Optionally wait for the batch ---------------------------------------------------
if "$WAIT"; then
  say "Waiting for the batch to finish (~15 min for a cold build)"
  while true; do
    STATUS=$(aws codebuild batch-get-build-batches --ids "$BATCH_ID" \
      --query 'buildBatches[0].buildBatchStatus' --output text)
    case "$STATUS" in
      IN_PROGRESS) sleep 30 ;;
      SUCCEEDED) ok "batch SUCCEEDED"; break ;;
      *)
        aws codebuild batch-get-build-batches --ids "$BATCH_ID" \
          --query 'buildBatches[0].buildGroups[?currentBuildSummary.buildStatus!=`SUCCEEDED`].{id:identifier,status:currentBuildSummary.buildStatus}' \
          --output table || true
        die "batch finished with status ${STATUS}"
        ;;
    esac
  done
fi

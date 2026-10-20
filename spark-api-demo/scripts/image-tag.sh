#!/usr/bin/env bash
# Prints the image tag for the current build inputs:
#   <submodule-short-sha>-p<pipeline-hash>
# The upstream source alone is NOT sufficient: the pipeline files
# (prepare-context.sh, base-image-map.env, buildspecs) transform the build
# context, so image content changes even when the submodule SHA does not
# (observed: nodes kept stale cached images under a pure source-SHA tag).
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_SHORT=$(git -C "$PROJECT_DIR/spark-api" rev-parse --short HEAD)
# The inspector sources are overlaid into the build zip too — include them
# so an inspector change re-tags (a rebuilt image under an unchanged tag
# would be cached stale on the nodes).
PIPE_HASH=$( { cat "$PROJECT_DIR"/pipeline/prepare-context.sh \
                   "$PROJECT_DIR"/pipeline/base-image-map.env \
                   "$PROJECT_DIR"/pipeline/buildspec-service.yml \
                   "$PROJECT_DIR"/pipeline/buildspec-frontend.yml; \
               find "$PROJECT_DIR"/inspector -type f -not -name '*.pyc' -not -path '*/__pycache__/*' | LC_ALL=C sort | xargs cat; } \
            | { md5 -q /dev/stdin 2>/dev/null || md5sum | cut -d' ' -f1; } | cut -c1-8)
printf '%s-p%s\n' "$GIT_SHORT" "$PIPE_HASH"

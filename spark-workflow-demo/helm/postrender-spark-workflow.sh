#!/usr/bin/env bash
# Helm postrenderer for the upstream umbrella (documented workarounds,
# upstream stays unmodified; issues are reported upstream):
#
# 1. spicedb-operator v1.23.0 does not know the chart argument `--crd=/crds`
#    (prints usage and crashes); the boolean `--crd` in turn requires CRD
#    write permissions the chart's minimal ClusterRole does not grant.
#    The SpiceDBCluster CRD is already installed by the cluster-config
#    chart — the argument is dropped without replacement.
#
# 2. docling-rq worker: the GKE GPU nodeSelector and nvidia.com/gpu
#    resources from the chart defaults cannot be removed via values (Helm
#    merges maps and drops null overrides across two subchart levels,
#    helm#12511). In CPU mode (argument "cpu") both are stripped;
#    in GPU mode the nvidia resources are kept.
#
# Usage: postrender-spark-workflow.sh [cpu|gpu]   (default: cpu)
set -euo pipefail
MODE="${1:-cpu}"

if [ "$MODE" = "gpu" ]; then
  sed \
    -e '/^ *- --crd\(=\/crds\)\{0,1\}$/d' \
    -e '/^ *cloud\.google\.com\/gke-accelerator:/d'
else
  sed \
    -e '/^ *- --crd\(=\/crds\)\{0,1\}$/d' \
    -e '/^ *cloud\.google\.com\/gke-accelerator:/d' \
    -e '/^ *nvidia\.com\/gpu:/d'
fi

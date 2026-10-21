#!/usr/bin/env bash
# Helm postrenderer for the upstream spark-platform umbrella.
#
# 0.2.x needed two patches here (spicedb-operator `--crd=/crds`, docling-rq GKE
# GPU nodeSelector/resources). Neither manifest exists in the 0.3.0 chart tree:
# SpiceDB is a plain Deployment in our platform chart, Docling is our own
# docling-rq release with values that set no GPU defaults. Measured with
# `git grep -e '--crd' -e gke-accelerator -e nvidia.com/gpu v0.3.0 -- helm`:
# no hit in a manifest. The hook stays wired (helm provider `postrender`) as
# the documented place for the next upstream workaround; today it passes the
# render through unchanged.
set -euo pipefail
cat

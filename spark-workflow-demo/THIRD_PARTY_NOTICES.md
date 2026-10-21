# Third-Party Notices — spark-workflow-demo

This demo project builds on third-party open-source software.

## Included Upstream Code

| Component | Source | License | Inclusion |
|---|---|---|---|
| SPARK Workflow | https://gitlab.opencode.de/bmds/planungs-und-genehmigungsbeschleunigung/spark-workflow | EUPL-1.2 | Git submodule `spark-workflow/` (tag v0.3.0), unmodified; container images from `registry.opencode.de` |
| SPARK Workflow `docling-rq` Helm chart | same repository, tag v0.2.3, `helm/charts/sources/external/docling-rq` | EUPL-1.2 | Copied to `helm/docling-rq/` (the 0.3.0 release dropped the chart). Changes: no bundled redis subchart (ElastiCache Valkey via `redisUrl.secretName`), CPU worker defaults; provenance in `helm/docling-rq/Chart.yaml` |

Third-party licenses of the upstream project: see `spark-workflow/THIRD_PARTY_LICENSES/`.

## Key Deployed Open-Source Components (Selection)

| Component | License | Source |
|---|---|---|
| Temporal 1.31.2 | MIT | official Helm chart 1.6.0 (upstream wrapper `04-shared-services/temporal`) |
| Keycloak 26 | Apache-2.0 | container image quay.io/keycloak |
| oauth2-proxy | MIT | quay.io/oauth2-proxy (fallback, disabled) |
| SpiceDB v1.51.0 | Apache-2.0 | ghcr.io/authzed/spicedb, plain Deployment in `helm/platform` |
| Qdrant 1.17 | Apache-2.0 | official Helm chart 1.17.0 (https://qdrant.github.io/qdrant-helm) |
| Docling Serve v1.14.3 | MIT | quay.io/docling-project (docling-rq chart, see above) |
| LiteLLM | MIT | ghcr.io/berriai/litellm |
| text-embeddings-inference (TEI) | Apache-2.0 | ghcr.io/huggingface/text-embeddings-inference |
| Envoy Gateway | Apache-2.0 | CNCF |
| External Secrets Operator | Apache-2.0 | CNCF |
| cert-manager | Apache-2.0 | CNCF |
| ClamAV (clamav-api v2.0.0) | GPL-2.0 (ClamAV), MIT (API wrapper) | ghcr.io/devhatro/clamav-api, upstream chart `04-shared-services/clamav` |
| unoserver / LibreOffice | MIT / MPL-2.0 | registry.opencode.de image `unoserver:3.5`, upstream chart |
| OpenTelemetry Collector | Apache-2.0 | otel/opentelemetry-collector-contrib (upstream `environment-config` chart) |
| Valkey (client-side RQ/redis-py when using ElastiCache) | BSD-3-Clause | AWS ElastiCache for Valkey |

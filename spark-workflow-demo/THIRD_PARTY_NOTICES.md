# Third-Party Notices — spark-workflow-demo

This demo project builds on third-party open-source software.

## Included Upstream Code

| Component | Source | License | Inclusion |
|---|---|---|---|
| SPARK Workflow | https://gitlab.opencode.de/bmds/planungs-und-genehmigungsbeschleunigung/spark-workflow | EUPL-1.2 | Git submodule `spark-workflow/`, unmodified; container images from `registry.opencode.de` |

Third-party licenses of the upstream project: see `spark-workflow/THIRD_PARTY_LICENSES/`.

## Key Deployed Open-Source Components (Selection)

| Component | License | Source |
|---|---|---|
| Temporal | MIT | official Helm chart (upstream wrapper) |
| Keycloak | Apache-2.0 | container image quay.io/keycloak |
| oauth2-proxy | MIT | quay.io/oauth2-proxy |
| SpiceDB / SpiceDB Operator | Apache-2.0 | upstream wrapper chart |
| Qdrant | Apache-2.0 | upstream wrapper chart |
| Docling / Docling Serve | MIT | quay.io/docling-project |
| LiteLLM | MIT | upstream Helm/container |
| Envoy Gateway | Apache-2.0 | CNCF |
| External Secrets Operator | Apache-2.0 | CNCF |
| cert-manager | Apache-2.0 | CNCF |
| ClamAV | GPL-2.0 | upstream wrapper chart |
| unoserver / LibreOffice | MIT / MPL-2.0 | upstream wrapper chart |
| Valkey (client-side RQ/redis-py when using ElastiCache) | BSD-3-Clause | AWS ElastiCache for Valkey |

This list will be completed during implementation (incl. exact chart/image versions).

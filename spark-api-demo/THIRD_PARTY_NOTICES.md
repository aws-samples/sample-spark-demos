# Third-Party Notices — spark-api-demo

This demo project builds on third-party open-source software.

## Included Upstream Code

| Component | Source | License | Inclusion |
|---|---|---|---|
| SPARK API | https://gitlab.opencode.de/bmds/planungs-und-genehmigungsbeschleunigung/spark-api | EUPL-1.2 | Git submodule `spark-api/`, unchanged; container images are built from the submodule source code via CodeBuild |

Third-party licenses of the upstream project: see `spark-api/THIRD_PARTY_LICENSES/`.

Note: Container images built from the submodule contain EUPL-1.2-licensed
code and its dependencies; they are stored only in the private ECR registry of
the demo account and are not redistributed.

## Deployed Open-Source Components

As deployed by this demo (images/charts pinned in `helm/platform/values.yaml`
and `terraform/modules/k8s-addons`):

| Component | License | Deployment |
|---|---|---|
| RabbitMQ (`rabbitmq:4.0-management`) | MPL-2.0 | StatefulSet, platform chart |
| Qdrant (`qdrant:v1.15.5`) | Apache-2.0 | StatefulSet, platform chart |
| Neo4j Community (`neo4j:5-community`) | GPL-3.0 | StatefulSet, platform chart |
| LiteLLM (`litellm:main-stable`) | MIT | Deployment, platform chart |
| Text Embeddings Inference (`text-embeddings-inference:cpu-1.8`) | Apache-2.0 | Deployment, platform chart (model: BAAI/bge-m3, MIT) |
| PostgreSQL client image (`postgres:16`, db-init job) | PostgreSQL License | Job, platform chart |
| Alpine (`alpine:3.20`, rabbitmq-init job) | MIT (distro; packages various) | Job, platform chart |
| Keycloak (`keycloak:26.0`) | Apache-2.0 | Deployment, platform chart (auth perimeter) |
| oauth2-proxy (`oauth2-proxy:v7.8.1`) | MIT | Deployment, platform chart (auth perimeter) |
| Python (`python:3.12-slim`, demo-inspector base) | PSF-2.0 (distro packages various) | Deployment, umbrella chart |
| FastAPI / uvicorn / httpx / boto3 (demo-inspector deps) | MIT / BSD-3-Clause / BSD-3-Clause / Apache-2.0 | Inside the demo-inspector image |
| ingress-nginx | Apache-2.0 | Helm, k8s-addons |
| External Secrets Operator | Apache-2.0 | Helm, k8s-addons |
| cert-manager | Apache-2.0 | Helm, k8s-addons |
| external-dns | Apache-2.0 | Helm, k8s-addons |
| metrics-server | Apache-2.0 | Helm, k8s-addons |
| aws-load-balancer-controller | Apache-2.0 | Helm, k8s-addons |

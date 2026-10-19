# Demo inspector — MIT-0 demo tooling, NOT part of the upstream product.
# Serves the browser overlay (inspector.js) and an SSE stream aggregating
# what happens behind the API: LiteLLM request log (-> Amazon Bedrock),
# RabbitMQ queue activity, CloudWatch Bedrock invocation metrics.
#
# Base image pinned by digest (multi-arch index of python:3.12-slim at the
# time of pinning) so the build is reproducible; refresh deliberately:
#   TOKEN=$(curl -s "https://public.ecr.aws/token/?scope=repository:docker/library/python:pull" | jq -r .token)
#   curl -sI -H "Authorization: Bearer $TOKEN" \
#     -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
#     https://public.ecr.aws/v2/docker/library/python/manifests/3.12-slim | grep -i docker-content-digest
FROM public.ecr.aws/docker/library/python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

USER 65534
EXPOSE 8000
# Kubernetes drives readiness through the Deployment probe; this keeps a
# plain `docker run` honest as well (same /demo-inspector/health endpoint).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/demo-inspector/health', timeout=4).status == 200 else 1)"]
# Binds all interfaces INSIDE the pod network namespace only — the port is
# never published beyond the cluster (ClusterIP Service, OIDC-gated ingress).
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

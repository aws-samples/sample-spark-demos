# docling-rq

Helm chart for the Docling-Serve RQ document parsing service.

Deploys the Docling-Serve API server backed by a Redis Queue (RQ) worker pool.
Workers process document parsing and layout analysis jobs asynchronously.
An internal Redis instance is bundled via the project `redis` subchart.

> **External images:** This chart references public Docling images from GHCR and
> Redis images from Docker Hub. These images are external dependencies and are
> not published or maintained in the Spark Workflow repository.

## What this chart creates

| Resource | Notes |
|---|---|
| `Deployment` (API server) | Docling-Serve HTTP API on port 5001 |
| `Deployment` (worker) | RQ worker pool — GPU by default, configurable for CPU |
| `Service` | ClusterIP on port 80 → 5001 |
| `PodDisruptionBudget` | `minAvailable: 1` for the API server |
| Redis `StatefulSet` + `Service` | Bundled via the `redis` subchart (`redis.enabled: true`) |

## Chart tree

```
/charts
└── 04-shared-services/
    └── docling-rq/
        ├── templates/            API server, worker, Service, PDB templates
        └── charts/
            └── redis/            project redis subchart
```

## Installing

```bash
helm dependency update
helm upgrade --install docling-rq . \
  -f values.yaml \
  --namespace agent-services \
  --create-namespace
```

When deployed via `agent-services`, no standalone install is needed.

## Worker configuration

The worker Deployment defaults to GPU mode (CUDA, `nvidia-l4` node selector):

```yaml
worker:
  enabled: true
  replicaCount: 2
  device: "cuda:0"
  resources:
    requests:
      nvidia.com/gpu: "1"
    limits:
      nvidia.com/gpu: "1"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-l4
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```

To run on CPU nodes, override:

```yaml
worker:
  device: cpu
  resources:
    requests:
      cpu: "4"
      memory: 32Gi
    limits:
      cpu: "8"
      memory: 48Gi
  nodeSelector: {}
  tolerations: []
  extraEnv: []    # remove LD_LIBRARY_PATH
```

## Redis URL

`DOCLING_SERVE_ENG_RQ_REDIS_URL` is injected into every container. The URL
source depends on whether Redis authentication is enabled:

| Scenario | How URL is injected |
|---|---|
| `redis.auth.enabled: false` (default) | URL constructed from the Redis service FQDN — no Secret needed |
| `redis.auth.enabled: true` with password | Redis subchart creates the Secret; `redisUrl.secretName` set automatically |
| `redis.auth.enabled: true` with `existingSecret` | Set `redisUrl.secretName` and `redisUrl.key` to reference a pre-existing Secret |

This chart does **not** auto-generate a Redis password. Supply one explicitly or
reference an externally managed Secret.

## Redis subchart

The bundled Redis instance (`redis.enabled: true`) uses a fixed service name
to keep the URL stable across release name changes:

```yaml
redis:
  fullnameOverride: "docling-rq-redis"
  auth:
    enabled: false
  persistence:
    size: 8Gi
    storageClass: ""
```

Set `redis.enabled: false` to connect to an external Redis instance and provide
the URL via `redisUrl.secretName`.

## Key values reference

| Key | Default | Description |
|---|---|---|
| `image.repository` | `<registry>/infra/docling-serve-cu128` | API server container image |
| `replicaCount` | `1` | API server replicas |
| `worker.enabled` | `true` | Deploy RQ worker Deployment |
| `worker.replicaCount` | `2` | Worker replicas |
| `worker.device` | `cuda:0` | Docling device — `cuda:0` for GPU, `cpu` for CPU nodes |
| `docling.engKind` | `rq` | Queue engine — always `rq` for this chart |
| `docling.numThreads` | `4` | Docling processing thread count |
| `docling.maxDocumentTimeout` | `3600` | Max seconds for a single document job |
| `redis.enabled` | `true` | Deploy bundled Redis instance |
| `redis.fullnameOverride` | `docling-rq-redis` | Fixed Redis service name |
| `redis.auth.enabled` | `false` | Enable Redis password authentication |
| `redisUrl.secretName` | `""` | Secret name holding the Redis URI (when auth is enabled) |
| `pdb.enabled` | `true` | Deploy PodDisruptionBudget for the API server |

## Placeholder reference

| Placeholder | Description |
|---|---|
| `<container-registry>` | Container image registry host and path prefix |
| `<image-tag>` | Image tag or `@sha256:<digest>` |

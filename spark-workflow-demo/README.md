# SPARK Workflow on AWS EKS — Demo Deployment

Fully automated demo deployment of [SPARK Workflow](https://gitlab.opencode.de/bmds/planungs-und-genehmigungsbeschleunigung/spark-workflow) (EUPL-1.2) on Amazon EKS — open-source core, AWS managed services as the infrastructure foundation.

> **This is sample code, for non-production usage.** You should work with
> your security and legal teams to meet your organizational security,
> regulatory and compliance requirements before deployment. The
> [threat model](../docs/THREAT-MODEL.md) lists the demo-only risks this
> deployment accepts and the hardening required before any production use.

> Status: **Deployed & end-to-end verified** (2026-08-18/19): 72 app pods Running,
> Keycloak login via Envoy Gateway OIDC → SPA loads, `/api/identity/me` returns the
> demo user (verified JWT), chat via Bedrock `gpt-oss-120b` and embeddings via
> TEI `BGE-M3` respond through LiteLLM. Presenter runbook: [DEMO.md](DEMO.md).

## TL;DR — executive summary

The German government's open-source **SPARK Workflow** platform (document
management + AI-assisted permitting workflows) runs **unmodified** on AWS:
every application component stays open source inside one EKS cluster, and
AWS contributes exactly the commodity substrate — managed PostgreSQL,
object storage, cache, secrets, DNS/TLS and Bedrock as the LLM backend
(serving an open-weights model). One `make apply` builds the whole
environment from an empty account; one `make destroy` removes it. Login,
document upload, AI analysis pipeline and workflow orchestration are
verified end to end.

## Why this demo is built this way

1. **Digital sovereignty is the point of the upstream project** — so the
   demo never replaces an application component with a proprietary AWS
   service (no Cognito, no Neptune, no MQ drop-in). What you can run
   on-prem, you run here: Keycloak, Temporal, Qdrant, SpiceDB, Envoy,
   LiteLLM, TEI — all in-cluster, all swappable back.
2. **AWS as substrate, not lock-in**: where upstream says "any PostgreSQL /
   any S3-compatible store / any Redis works", the demo plugs in RDS,
   S3 and ElastiCache — managed operations for the parts that are
   commodity anyway, each behind upstream's own configuration contract.
3. **LLM without GPUs and without API keys**: LiteLLM serves the exact
   upstream model names and routes to Amazon Bedrock (`gpt-oss-120b`,
   open-weights) via pod identity — the 9 AI modules run without a single
   override or credential.
4. **Repeatability as proof**: the submodule is read-only; every adaptation
   is Terraform/Helm in this repo, every deviation documented with the
   observed failure that forced it. `destroy → apply` from zero has been
   verified hands-off.

## Architecture

Legend: 🟦 **blue** = open source in-cluster (solid border = ships with the
upstream project, dashed = added by this demo) · 🟧 **orange** = open-source
engine as AWS managed service · ⬛ **dark** = AWS-native managed substrate.
(Mermaid cannot load the official AWS architecture icons portably, so the
diagram follows the AWS color language instead.)

```mermaid
flowchart TB
    user(["Browser / Presenter"])

    subgraph aws["AWS account — eu-central-1"]
        direction TB
        r53["Amazon Route53 + Let's Encrypt<br/>(external-dns, cert-manager DNS-01)"]
        nlb["AWS Network Load Balancer"]

        subgraph eks["Amazon EKS — cluster spark-demo"]
            direction TB
            subgraph edgezone["Edge and identity"]
                envoy["Envoy Gateway<br/>OIDC SecurityPolicy per host"]
                kc["Keycloak 26<br/>realm local"]
                spicedb["SpiceDB + operator"]
            end
            subgraph app["SPARK Workflow — upstream v0.2.1, unmodified images"]
                fe["Frontend SPA (/app)"]
                svcs["19 services<br/>DMS, Normen, Identity, ..."]
                ai["9 AI modules"]
                temporal["Temporal + workers<br/>(workflow engine)"]
                docling["Docling Serve + RQ"]
                qdrant["Qdrant (vectors)"]
                clam["ClamAV / unoserver"]
            end
            subgraph plat["Demo platform layer"]
                litellm["LiteLLM gateway<br/>serves upstream model names"]
                tei["TEI — BGE-M3 embeddings"]
                eso["External Secrets Operator"]
                seeds["Seed and bootstrap jobs<br/>(Keycloak realm, lookup data)"]
            end
        end

        rds["Amazon RDS for PostgreSQL 16<br/>22 DBs + pgvector"]
        s3["Amazon S3<br/>dms · quarantine · temporal"]
        valkey["Amazon ElastiCache for Valkey<br/>Docling RQ broker"]
        asm["AWS Secrets Manager"]
        bedrock["Amazon Bedrock<br/>gpt-oss-120b (chat, open weights)<br/>Pixtral Large (vision)"]
    end

    user -->|HTTPS| r53 --> nlb --> envoy
    envoy -->|OIDC login| kc
    envoy --> fe
    envoy --> svcs
    svcs --> temporal --> ai
    ai --> litellm --> bedrock
    ai --> tei
    ai --> docling --> valkey
    svcs --> qdrant
    svcs --> rds
    kc --> rds
    spicedb --> rds
    svcs -->|presigned URLs| s3
    eso --> asm

    class envoy,kc,spicedb,fe,svcs,ai,temporal,docling,qdrant,clam,litellm,tei,eso oss
    class seeds demo
    class rds,valkey awsoss
    class s3,asm,bedrock,r53,nlb awsnative

    classDef oss fill:#146EB4,stroke:#0b3a63,color:#ffffff
    classDef demo fill:#146EB4,stroke:#0b3a63,color:#ffffff,stroke-dasharray:6 3
    classDef awsoss fill:#FF9900,stroke:#8a5200,color:#111111
    classDef awsnative fill:#232F3E,stroke:#000000,color:#ffffff
    style aws fill:#fafafa,stroke:#cccccc
    style eks fill:#f2f7fb,stroke:#146EB4
    style app fill:#e8f1f9,stroke:#146EB4
    style plat fill:#eef6ee,stroke:#5a8a5a,stroke-dasharray:6 3
    style edgezone fill:#e8f1f9,stroke:#146EB4
```

**Upstream vs. demo layer:** everything inside "SPARK Workflow" plus
Keycloak/SpiceDB/Envoy/Qdrant/LiteLLM/TEI is the upstream open-source
stack (deployed through the upstream umbrella chart with values overlays);
the dashed pieces (seed/bootstrap jobs) and the entire AWS substrate are
this demo's Terraform/Helm. The submodule itself is never modified — see
"Deviations" below for every overlay, with the observed reason.

### Component detail

| Component | Hosting | Service |
|---|---|---|
| SPARK Workflow (frontend, 19 services, 9 AI modules) | EKS | Upstream Helm charts (`00-spark-workflow` umbrella), images from `registry.opencode.de` (v0.2.1) |
| Workflow engine (Temporal) | EKS | Official Temporal chart (upstream wrapper), state in RDS |
| PostgreSQL + pgvector (22 databases) | **AWS Managed** | Amazon RDS for PostgreSQL |
| Object storage (documents, Temporal payloads, quarantine) | **AWS Managed** | Amazon S3 (S3-compatible interface, presigned URLs) |
| Redis (Docling RQ broker) | **AWS Managed** (optional) | Amazon ElastiCache for Valkey |
| Vector database (Qdrant) | EKS | Upstream chart |
| Identity (Keycloak) + oauth2-proxy | EKS | Open-source in-cluster deployment, state in RDS |
| Authorization (SpiceDB + operator) | EKS | Upstream chart, state in RDS |
| Document processing (Docling Serve) | EKS | CPU mode by default, GPU node group optional |
| LLM gateway (LiteLLM) | EKS | Serves the upstream model names, backend Amazon Bedrock (swappable) |
| API routing (Envoy Gateway) | EKS | CNCF Envoy Gateway behind an AWS NLB |
| Secrets | **AWS Managed** | AWS Secrets Manager, synchronized via External Secrets Operator |
| ClamAV, unoserver | EKS | Upstream charts |

## Deployment

- **Terraform** provisions the entire AWS infrastructure and the platform addons.
- **Helm** deploys the SPARK Workflow stack via the upstream umbrella charts with demo overrides from `helm/`.
- Upstream code lives unmodified in the submodule [`spark-workflow/`](spark-workflow/).
- Configuration comes entirely from the root `.env` (untracked, see `../.env.example`) — no account/zone IDs in Git.

```bash
# in the repo root: cp .env.example .env && set the values
make init      # terraform init
make plan      # preview
make apply     # bring up the demo
make destroy   # full teardown
make validate  # fmt-check + terraform validate (no AWS access)
```

### Users & roles

The demo follows the upstream identity model exactly (audited against
`docker/keycloak/bootstrap.sh` and the `authentification` shared lib):

- Roles are **Keycloak realm roles** `admin`, `user`, `service` — the backend
  derives the application role from the `realm_access.roles` JWT claim
  (precedence admin > user > service). Every human user needs `user` or
  `admin`, otherwise the frontend rejects the session.
- The bootstrap job (platform chart) creates the realm, the confidential
  client `local-client` (with the audience mapper and the realm-management
  `view-*` grants its service account needs for the app's user listing), and
  one demo user with realm roles `["admin", "user"]` — the same set the
  upstream local stack creates.
- **Adding users is done in Keycloak** (upstream has no in-app user
  management; it is a roadmap item there): Keycloak admin console →
  realm `local` → Users → Create user (set email + password, mark email
  verified) → Role mapping → assign realm role `user` (and `admin` if
  wanted). The app picks new users up automatically via its `/users`
  endpoint. Admin console URL and credentials: see [DEMO.md](DEMO.md) §1/§11.
- The upstream seeds for lookup data (procedure types etc.) run
  automatically after every deploy; opt out with
  `SPARK_WORKFLOW_SEED_JOBS_ENABLED=false` in `.env`.

### LLM integration

- Chat/reasoning: **Amazon Bedrock** via the **LiteLLM** gateway intended by upstream, model **`gpt-oss-120b`** (open-weights, on-demand in `eu-central-1`). Access via EKS Pod Identity, region configurable via `BEDROCK_REGION` (default `eu-central-1`).
- Vision (VLM enhancement stage of the extraction pipeline): **Pixtral Large 2502** via the EU cross-region inference profile `eu.mistral.pixtral-large-2502-v1:0` — routing stays inside the EU geography. Weights are published (Mistral Research License, i.e. more restrictive than Apache-2.0); the only weights-available vision model in the EU profiles today. Configurable via `BEDROCK_VLM_MODEL_ID`.
- Embeddings: **BGE-M3** via an in-cluster **TEI** deployment (text-embeddings-inference, CPU) — exactly the upstream embedding model.
- Any other OpenAI-compatible backend remains possible via configuration.

## Deviations from the upstream defaults — what, where, why

The upstream code (submodule) is **unmodified**. All deviations live in
this repo: Terraform (`terraform/`), demo values overlay
(`helm/values/spark-workflow.demo.yaml.tftpl`), platform chart
(`helm/platform/`), cluster-config chart (`helm/cluster-config/`), and a
Helm postrenderer (`helm/postrender-spark-workflow.sh`). Every deviation was
verified during the first live deploy; "observed" = an error that actually
occurred and forced the change.

### A. AWS managed services instead of in-cluster operation

| Component | Upstream expectation | Demo on AWS | Why |
|---|---|---|---|
| PostgreSQL (+pgvector) | CNPG cluster in-cluster ("Any PostgreSQL provider works") | **Amazon RDS for PostgreSQL 16**, one instance, all DBs (app DBs + `temporal`/`temporal_visibility` + `spicedb` + `keycloak`) | Explicitly supported by upstream; fully replaces the CNPG operator. DB/role creation + pgvector + the laws seed are handled by the idempotent `db-init` job (platform chart, pre-install hook) — logic taken 1:1 from the upstream compose, seed SQL is staged from the submodule to S3 by Terraform |
| Object storage | MinIO / S3-compatible (Rook/Ceph) | **Amazon S3** (4 buckets: dms, temporal-payloads, temporal-archival, quarantine) | The app speaks endpoint+keys incl. presigned URLs → S3 is the reference. CORS for browser uploads on the dms **and quarantine** buckets — with ClamAV enabled (default), presigned user uploads target the quarantine bucket first (observed: uploads failed in the browser until the quarantine bucket carried the CORS rule); access via a dedicated IAM user scoped to the buckets (the app expects static keys — documented demo deviation vs. short-lived credentials) |
| Redis (Docling RQ broker) | Redis container in the docling-rq chart | **ElastiCache for Valkey** (TLS + AUTH, `rediss://`) | The chart natively supports an external Redis URL (`redis.enabled=false` + `redisUrl` secret) — a clean drop-in that demonstrates the managed-OSS pattern. Flag `SPARK_WORKFLOW_VALKEY_ENABLED` |
| Secrets | External-Secrets-compatible service (e.g. Vault) | **AWS Secrets Manager** as the ESO backend | Exactly the ESO pattern required by upstream. Terraform generates ALL credentials and stores them in ASM; ExternalSecrets create the ~26 K8s secrets with the names/keys the upstream charts expect (extracted from a full rendering) |
| LLM backend | Pharia AI / vLLM behind LiteLLM | **Bedrock `openai.gpt-oss-120b-1:0`** via LiteLLM (Pod Identity, `BEDROCK_REGION`, default `eu-central-1`) + **TEI** in-cluster for BGE-M3 | No GPU cluster needed; the model itself is open-weights. LiteLLM serves the models under **exactly the upstream names** `self-hosted/gpt-oss-120b` and `self-hosted/bge-m3` — so the 9 AI modules need **no** model-name overrides (single exception: `VLLM_MODEL`, see section D) |
| VLM (vision) backend | `VLLM_MODEL=self-hosted/gpt-oss-120b` (upstream default) | **Bedrock Pixtral Large** via the EU profile `eu.mistral.pixtral-large-2502-v1:0`, served by LiteLLM as `self-hosted/pixtral-large`; overlay sets `VLLM_MODEL` to that name | gpt-oss-120b is text-only — the VLM stage sends image content blocks (observed: Bedrock 400 "This model doesn't support the image content block" on every element, `vlm-batch-processing` fails the document). Only weights-available vision model in the EU cross-region profiles; `BEDROCK_VLM_MODEL_ID` swaps it |
| DNS/TLS | "cert-manager optional", ingress external | **Route53** (external-dns, source `gateway-httproute`) + **Let's Encrypt DNS-01** (cert-manager, Route53 solver) | Fully automatic given the hosted zone ID from `.env`; DNS-01 avoids the chicken-and-egg problem with HTTP reachability |
| Kafka/MSK, Amazon MQ | — | **not used** | SPARK Workflow uses neither Kafka nor RabbitMQ |

### B. EKS-specific — it does not run without these adjustments

| Adjustment | Location | Why (observed) |
|---|---|---|
| Node SG: self-ingress **all ports** | `terraform/modules/eks` | The EKS module only opens ephemeral ports (≥1025) between nodes. The upstream services expose **pod port 80** → Envoy could not reach backends on other nodes (`503 upstream connect timeout` after successful login) |
| **100 GiB gp3 root volumes** | `terraform/modules/eks` | ~30 container images in the stack; the 20 GiB default volumes filled up → `disk-pressure` taints + pod evictions |
| **gp3 as the default StorageClass** (gp2 de-defaulted) | `terraform/modules/k8s-addons` | The EKS default gp2 is in-tree/legacy; charts with `storageClassName: ""` (ClamAV!) otherwise do not provision at all |
| **Qdrant node group pinned to ONE AZ** | `terraform/modules/eks` (`qdrant_subnet_index`) | Qdrant PVs are zonal EBS volumes. Multi-AZ node group: node replacement landed in a different AZ → PVs stranded (`didn't match PersistentVolume's node affinity`) |
| **4× m6i.2xlarge** default pool | `.env` `SPARK_WORKFLOW_NODE_COUNT=4` | 73 pods with upstream resource requests do not fit on 3 nodes (`Insufficient cpu/memory`) |
| **amd64 instances** (no Graviton) | `terraform/modules/eks` | Upstream only publishes amd64 images |
| NLB via **aws-load-balancer-controller** | `helm/cluster-config` (EnvoyProxy annotations) | The Envoy Gateway service gets an internet-facing NLB (ip targets) — the only public entry point |
| **EKS Pod Identity** instead of IRSA | `terraform/modules/k8s-addons` | Roles for EBS CSI, LB controller, ESO, cert-manager, external-dns, and LiteLLM→Bedrock (`bedrock:InvokeModel*`, scoped to foundation models) |

### C. Perimeter auth & API routing (Envoy Gateway)

| Adjustment | Why |
|---|---|
| **Envoy Gateway OIDC** (SecurityPolicy) instead of oauth2-proxy | Upstream names "Envoy + OIDC provider" as the target design; one auth point + native prefix rewrites in the gateway. oauth2-proxy remains as a fallback flag in the platform chart (`oauth2Proxy.enabled`) |
| OIDC **back-channel via `backendRefs`** to the Keycloak service | Token redeem/JWKS via the public hostname = hairpin through the internet-facing NLB → fails from the Envoy pods (observed: 503 right after login). The front-channel (browser redirects) stays public |
| **One SecurityPolicy per host** (frontend-oidc, temporal-oidc) instead of one policy for both routes | `redirectURL` must match the host where the flow starts: Envoy's oauth2 filter stores CSRF/session cookies on the originating host — if the callback lands on a different host, the cookies are missing (observed: "OAuth flow failed" after login on the Temporal UI). Each host also needs its own redirect URI in the Keycloak client (the bootstrap job registers both) |
| **15 API routes with URLRewrite** on the frontend host | The routing contract lives in the frontend code (`configureClients.ts` + Vite proxy): `/api/<prefix>` → service, prefix stripped (exception `/temporal`). Upstream does not ship these routes ("ingress external") |
| **`/app` prefix strip** as a separate HTTPRoute (`frontend-app`) | The frontend image templates `VITE_BASE_URL=/app` into index.html, but its nginx serves from the web root — the gateway must rewrite `/app/...` → `/...` (observed: page loads via the nginx SPA fallback but every `/app/assets/*` request 404s → blank page). Separate route because the frontend route already carries 16 rules (the Kubernetes maximum per HTTPRoute); Gateway API matches the longest prefix across routes of the same hostname |
| BackendRef **port 80** | All upstream service charts expose service port 80 (observed: `ResolvedRefs=False PortNotFound` degraded the entire route) |
| **`AUTH_MODE=optional_verify_dry_run`** (instead of `disabled`/`strict`) | The mode upstream built for exactly this case: JWTs are **actually verified against Keycloak** (otherwise `/api/identity/me` can only return 401 — `disabled` does not parse a token at all), SpiceDB permission checks run as a dry-run. `strict` would require complete SpiceDB relationship seeds, which v0.2.1 does not ship. Switchable via the `auth_mode` variable |
| Keycloak: realm `local`, client `local-client`, audience mapper, demo user | Bootstrap job in the platform chart, derived 1:1 from the upstream script `docker/keycloak/bootstrap.sh` (same names → no hidden couplings) |
| identity-management-service gets `AUTH_CLIENT_ID` in addition to `AUTH_CLIENT_SECRET` | `GET /users` (user listing in the UI) fetches an admin-API token via client_credentials; the shared auth lib does not fall back to `AUTH_AUDIENCE` for this (observed: 500 "OIDC token request failed" on /users while /me/roles worked). Matches the upstream values contract (`identity-management-service` chart documents both) |
| **Keycloak admin surface denied at the gateway**: `/admin/master/**` + `/realms/master/**` → 403 via an `HTTPRouteFilter` `directResponse` on its own HTTPRoute (`keycloak-admin-denied`) | Upstream routes the whole Keycloak host with a single catch-all rule, so the `master` realm's admin console was reachable from the internet with only the bootstrap admin password in front of it (observed: a security scan of the live deployment cited `/realms/master/protocol/openid-connect/auth?client_id=security-admin-console`). Scope is deliberately **not** `/admin`: the console for every realm lives under `/admin/master/console`, while the token-protected admin REST API is `/admin/realms/<realm>` — and identity-management-service calls exactly that through the public hostname (`AUTH_BASE_URL`), so a blanket deny breaks `GET /users`. Verified after the change: console/master 403, `/admin/realms/local/users` 401 unauthenticated and 200 through the app, scripted OIDC login green. Admin access via `kubectl port-forward svc/keycloak 8080:8080` |
| **Source-IP allowlist on the public NLB**: `DEMO_ALLOWED_CIDRS` (root `.env`, comma-separated) → `loadBalancerSourceRanges` on the EnvoyProxy `envoyService` | A company or personal AWS account may not serve anything to unauthenticated callers, and a security scan counts the OIDC **login redirect** as exactly that — so route-level OIDC is not sufficient and the restriction has to sit at L4, where one value covers all three hostnames and both `:80`/`:443`. **Empty = open to the internet** (the from-zero default). Alternative for occasional demos: leave it open and `make destroy` afterwards |

### D. Workarounds for upstream chart gaps (candidates for upstream issues)

| Problem (observed) | Workaround |
|---|---|
| The spicedb chart passes `--crd=/crds` — invalid for operator v1.23.0 (prints usage, crashes) | The postrenderer removes the argument; the **SpiceDBCluster CRD is vendored** and installed in the cluster-config chart (the operator only installs CRDs at runtime — too late for Helm, which validates the CR in the same release) |
| Operator v1.23 still reconciles its CRD at startup; the minimal chart RBAC does not allow it (`cannot update customresourcedefinitions`) | Name-scoped ClusterRole only for `spicedbclusters.authzed.com` + role supplement for PDB/EndpointSlices (diff against the official `config/rbac/role.yaml` of the operator release) |
| The spicedb chart deploys a **CNPG `Cluster`** (CRD not present) and expects namespace `spicedb-operator` | `cluster.database.enabled=false` (SpiceDB → RDS via `datastore_uri`, supported by the chart); the namespace is created by Terraform |
| docling-rq: the GKE GPU `nodeSelector` + `nvidia.com/gpu` requests can **not** be removed via values (Helm merges maps; `null` overrides are dropped across two subchart levels, helm#12511) | The postrenderer strips both in CPU mode; CPU image `quay.io/docling-project/docling-serve-cpu`. GPU mode (`SPARK_WORKFLOW_GPU_ENABLED`) uses its own pool selector |
| The Temporal wrapper disables the schema jobs ("managed externally via CNPG") → `schema_version does not exist`, the server crashloops | Official chart schema jobs enabled (`schema.setup/update.enabled=true`); `createDatabase` stays off (the db-init job creates the DBs with the correct owner) |
| Nobody creates the Temporal namespace `default` → the `search-attributes` hook waits forever, the Helm install hangs | `server.config.namespaces.create=true` (chart feature) |
| The spicedb chart renders a ServiceAccount **`default`** → Helm refuses to install over the K8s auto-created SA | SA adoption before the install (Terraform, server-side apply with separate field managers for label/annotation) |
| The `landingpage` chart ships only a placeholder image; the `normenermittlung` module has no published v0.2.1 image | Both disabled via flag (documented gap) |
| The upstream default `VLLM_MODEL=self-hosted/gpt-oss-120b` points the **vision** stage at a **text-only** model — with any backend that enforces modalities, every VLM element fails and there is no flag to skip the stage (observed: Bedrock 400 "image content block", document fails after successful extraction) | Overlay points `VLLM_MODEL` at `self-hosted/pixtral-large` (vision-capable, served by LiteLLM); everything else keeps upstream names |
| The lookup-data seeds (`python -m src.scripts.seed_data` for project-logic, formal-completeness, administrative-file-draft) are only wired in the upstream process-compose dev setup — the Helm charts do not include them, so a fresh cluster starts with empty lookup tables (observed: the UI cannot load procedure types) | Local `helm/seed-jobs` chart: a post-install/upgrade hook job waits for each service rollout and runs the idempotent upstream seed **inside the running service pod** (same image, same env — no wiring duplicated); deployed as its own release after the umbrella |
| Helm replaces lists: a custom `extraEnv` **displaces** the umbrella defaults (DB_NAMEs and model names disappeared) | The overlay carries the **complete union** of umbrella defaults + demo overrides; all `${...}` values quoted (the K8s API rejects unquoted numbers: `EnvVar.value` must be a string) |

### E. Behavior of the published v0.2.1 images

| Problem (observed) | Demo configuration |
|---|---|
| `modul-inhaltsextraktion` bakes in `TRANSFORMERS_OFFLINE=1` but does **not** contain the expected model cache → the guard model load crashes | `TRANSFORMERS_OFFLINE=0`/`HF_HUB_OFFLINE=0` + `HF_HOME=/tmp/hf` (non-root without HOME: default cache `/.cache` not writable → `PermissionError`) |
| `INJECTION_MODEL_TOKEN` requires `min_length=1` but is a bearer token for an **external** guard service (not part of the demo) | Non-empty placeholder; `INJECTION_MODEL_URL` points to localhost (flow documented as limited) |
| The frontend image templates `VITE_*` into `/usr/share/nginx/html` at startup and binds port 80 → `Permission denied` with the chart default user 65532 | `podSecurityContext` override to root — **documented demo deviation** (the upstream fix would be `--chown` in the image build + port ≥1024) |
| TEI/BGE-M3: warmup allocates for the full `max-batch-tokens` (16384) → OOMKilled even with 16 Gi | `--max-batch-tokens=4096` + 16 Gi limit |
| Modules validate `OTEL_ENDPOINT` with `min_length=1`, the umbrella partly sets `""` | Upstream local convention `http://localhost:4317` (the exporter degrades silently); a real collector = phase 2 |
| The SPA ships client-side origin allowlists for presigned storage URLs (`VITE_ALLOWED_UPLOAD_ORIGINS`, `VITE_ALLOWED_DOWNLOAD_ORIGINS`) that default to empty | Both set to the regional S3 endpoint in the frontend values — with an empty allowlist the SPA blocks every upload/download client-side before any request is sent (observed: "Hochladen fehlgeschlagen" although presigned URL generation succeeded and S3 never saw a request) |
| Temporal workers (`modul-*`, `llm-client`) connect to the Temporal frontend **once** at startup; when the frontend is not up yet, the worker coroutine dies with `RuntimeError: Failed client connect … Connection refused`, but the process and its health server stay alive, so the pod reads `Running 1/1` while nothing polls its task queue (observed after `make apply` from zero: 16 of 16 module pods and 3 of 3 `llm-client` pods dead for 30 min, `temporal task-queue describe` listed zero pollers, every uploaded document stayed `Scheduled`; a `rollout restart` fixed each one). The charts expose no worker-health endpoint and no init-container hook | Overlay sets an `exec` startup probe (10 min window) and liveness probe (3 × 30 s) on the 10 worker deployments that test the one observable fact: an established connection to the frontend (`grep ':1C41 01' /proc/1/net/tcp`, 0x1C41 = 7233). Verified: all 19 pods start with 0 restarts; with the frontend scaled to 0 all 19 are restarted by the liveness probe within 2 min, and after it returns every pod reconnects via the startup probe within 10 min |
| `temporal-job-service`'s chart startup probe allows 60 s (6 × 10 s); at cold start the alembic migration plus the Temporal connect take about that long under the 150m CPU limit (observed: both replicas killed by the startup probe 5–6 times, `connection refused` on `/startup`, uvicorn listening the moment SIGTERM arrived; Ready after 7 min) | `startupProbe.failureThreshold: 30` in the overlay (map merge keeps the chart's `httpGet`) |

#### Image tags per service (submodule at v0.2.3)

The submodule is pinned to the upstream release tag **v0.2.3**
(2026-10-12), the last release before the 0.3.0 restructuring. Between our
previous pin and v0.2.3 nothing in the Helm charts, the Keycloak bootstrap
script, the frontend routing contract or the seed scripts changed (the
chart tree is byte-identical), so the overlay below is unchanged apart from
image tags. The upstream charts still default every image to `v0.2.1`
(the 0.2.3 changelog says otherwise; upstream-issue candidate), and the
openCode registry only publishes a `v0.2.3` image for part of the
services. The overlay therefore pins per service:

| Image tag | Services | Note |
|---|---|---|
| **v0.2.3** (12) | frontend, document-management-service, agent-orchestration-service, administrative-file-draft, comment-service, examination-service, feedback-service, formal-completeness-check, fpp-service, identity-management-service, objections-management-service, plausibility-notes | Carries the 0.2.3 fixes we care about: document management signs internal upload URLs with `S3_ENDPOINT_URL` (we set `S3_ENDPOINT_URL` and `S3_EXTERNAL_URL` to the same regional endpoint, nothing to change) and the CVE dependency bumps. Python services now run on the ZenDiS hardened `python3:3.13-minimal` base; the venv stays on `PATH`, so the seed runner's `kubectl exec … python -m src.scripts.seed_data` keeps working |
| v0.2.1 (18) | project-logic-service, protocol-service, supplementary-requests-service, temporal-job-service, all `modul-*`, llm-client, gesetze-normen-/gesetzesbegruendung-/jura-db-service, rechtsaenderungs-monitoring | No `v0.2.3` image published; the next tag is `v0.3.0` from the restructured tree, which does not fit the 0.2.x charts. Consequence: the 0.2.3 **security fix for PII redaction (upstream issue #40, `modul-anonymisierung`)** and the prompt-schema fix (`modul-formale-pruefung`) are **not** in this deployment — see `../docs/THREAT-MODEL.md` B-4 |
| none | landingpage, normenermittlung | Still no published image (disabled, section D) |

Within the 0.2.x line there is no API-contract change between the two
tags, so the mixed set is uncritical. Verified statically (`helm template`
of the staged charts with this overlay through the postrenderer: 105
resources, the postrenderer removes exactly the three expected lines, 12 ×
`v0.2.3` / 18 × `v0.2.1` image references) and **verified live** on
2026-10-20 with `make apply` from zero (195 resources, 25 min, one
attempt): `scripts/verify.sh` green (6/6), scripted OIDC login with a
cookie jar (Keycloak form → Envoy callback → `/app/` 200, unauthenticated
API call → 302), project created, `demo-data/*.zip` uploaded through the
presigned-URL sequence of the SPA (generate URL → PUT → confirm → start
processing), `FileProcessingWorkflow` and `FVPWorkflow` completed (54
Temporal workflows), 64 `openai.gpt-oss-120b-1:0` and 10
`eu.mistral.pixtral-large-2502-v1:0` Bedrock invocations in `eu-central-1`
for one two-document ZIP, both documents assigned to a required document
type by the formal completeness check. The seed runner's `kubectl exec …
python -m src.scripts.seed_data` on the ZenDiS minimal base images printed
`All seeds completed.`. The two cold-start findings of that run are the
last two rows of the table above.

### F. Data protection and hardening defaults (deployment layer)

Added after a static review (checkov + semgrep over this repo's Terraform,
Helm and scripts) and a review of the deployment tree. Everything here is
in this repo's layer; none of it changes what the upstream charts deploy.

| Control | Location | Why / what it changes |
|---|---|---|
| **One customer-managed KMS key per environment** (`alias/<prefix>`, rotation on, 7-day deletion window) encrypts Secrets Manager entries, all S3 buckets (SSE-KMS + Bucket Keys), ElastiCache at rest, RDS Performance Insights and the exported RDS log groups | `terraform/modules/kms`, wired in `envs/demo/main.tf` | Key usage becomes auditable per principal in CloudTrail and revocable centrally. The ESO pod identity gets `kms:Decrypt` on exactly this key (`external_secrets_kms_key_arns`) — without it the module grants Decrypt on every key in the account. The S3 IAM user holds the matching `kms:GenerateDataKey*`/`Decrypt` so presigned browser uploads keep working |
| **S3 versioning + lifecycle** on every bucket (noncurrent versions expire after 7 days, abandoned multipart uploads after 7 days) | `terraform/modules/s3` | Overwrites and deletes stay recoverable for a demo day without the buckets growing without bound |
| **RDS**: CloudWatch log exports (`postgresql`, `upgrade`) into pre-created, KMS-encrypted log groups with 365-day retention, Performance Insights (free tier, KMS), Enhanced Monitoring (60 s), IAM database authentication (additive, services keep their passwords), `copy_tags_to_snapshot`, `deletion_protection` as a variable (`SPARK_WORKFLOW_RDS_DELETION_PROTECTION`, default false for the hands-off destroy) | `terraform/modules/rds-postgres` | Pre-creating the log groups keeps retention and encryption under Terraform; RDS would otherwise create never-expiring unmanaged groups on first export |
| **EKS public API endpoint fenced by `DEMO_ALLOWED_CIDRS`** (same list as the NLB; empty = open) | `terraform/modules/eks` (`cluster_endpoint_public_access_cidrs`) | One allowlist for both internet-facing surfaces. Include the address you run terraform/kubectl from, or the apply locks itself out |
| **Terraform registry modules pinned to the commit a release tag points at** (vpc v5.21.0, eks v20.37.2, eks-pod-identity v1.12.1) | `terraform/modules/{network,eks,k8s-addons}` | A `~>` range resolves to whatever the registry serves tomorrow; a commit hash does not |
| **Availability zones pinned by name** (`<region>a..c`), with a postcondition on the count | `terraform/modules/network` | A sorted-and-sliced zone list shifts the subnet layout when AWS adds a zone to the region; `availability_zone_names` overrides for regions with non-contiguous letters |
| **TEI model revision pinned** (`--revision=<commit>` of `BAAI/bge-m3`) | `helm/platform/values.yaml` (`tei.revision`) | The model is downloaded at pod start; a floating `main` would silently change what the demo embeds with |
| Static-analysis suppressions carry their reason inline (`#checkov:skip=…` / `# nosemgrep: …`) | Terraform + Helm files | Every remaining finding is a deliberate demo trade-off (single-AZ RDS/Valkey, no secret rotation, no bucket access logging/replication, static S3 keys, demo-grade teardown flags) and says so where it applies; the production checklist lives in `../docs/THREAT-MODEL.md` |

### G. Operational notes (AWS-specific)

- **EKS provider tokens expire after 15 min.** Long applies (node rollouts, Helm upgrade across ~20 deployments) can abort with `Unauthorized` → renew the AWS session and **repeat the same command**; all steps are idempotent.
- **Increasing `node_count` afterwards:** The EKS module ignores `desired_size` changes (autoscaler convention). Run `aws eks update-nodegroup-config ... --scaling-config` once to catch up, then `make apply`.
- **Teardown:** `make destroy` — buckets have `force_destroy`, secrets `recovery_window=0`, the KMS key a 7-day deletion window. (A complete destroy→apply cycle is still open as task 6.3.)
- **Applying this hardening to an environment created before it:** the KMS key, versioning, lifecycle, log groups and monitoring role are additive. Two changes replace resources: ElastiCache gets `kms_key_id` (replication group re-created, the RQ broker is stateless) and the Secrets Manager entries change their encryption key in place. Expect one RDS modification for the log exports/monitoring (`apply_immediately`).

## Directory layout

```
spark-workflow-demo/
├── spark-workflow/    # Upstream (git submodule, EUPL-1.2) — do not modify
├── terraform/         # IaC: VPC, EKS, RDS, S3, ElastiCache, Secrets, Addons
├── helm/              # Demo values/overrides for the upstream charts
├── scripts/           # Helper scripts (seed, smoke tests)
├── docs/              # Architecture and operations docs for the demo
├── CHANGELOG.md
├── LICENSE            # MIT-0 (demo code only)
└── THIRD_PARTY_NOTICES.md
```

## License

Demo code: MIT-0. Upstream submodule: EUPL-1.2 (unmodified). See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

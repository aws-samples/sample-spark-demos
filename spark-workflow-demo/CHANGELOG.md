# Changelog — spark-workflow-demo

All notable changes to this demo project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning: [SemVer](https://semver.org/lang/de/).

## [Unreleased]

### Added
- Optional corporate identity provider: with `EXTERNAL_OIDC_ISSUER_URL`/`_CLIENT_ID`/`_CLIENT_SECRET` set in the root `.env` (any OIDC issuer), the Keycloak bootstrap registers it as identity provider `corporate` in realm `local` (endpoints from the issuer's discovery document, realm roles `admin`+`user` for every brokered user) and makes the realm's browser login redirect straight to it, so the Keycloak login page never asks for a password. Empty = unchanged demo user. Values live in a Secrets Manager entry (`…/auth/external-oidc`), nothing provider-specific in the repository (README section C, THREAT-MODEL E-13).

### Fixed
- Temporal workers (`modul-*`, `llm-client`) that lose or never get their connection to the Temporal frontend are restarted automatically: exec startup probe (10 min window) and liveness probe (3 × 30 s) on an established connection to port 7233. Before, a worker whose first connect was refused at cold start died silently while its pod stayed `Running 1/1`, and every uploaded document stayed `Scheduled` until a manual `rollout restart` (observed on every module and `llm-client` after `make apply` from zero). README section E.
- `temporal-job-service` is no longer killed by its startup probe at cold start (`failureThreshold` 6 → 30; both replicas needed 5–6 restarts and 7 min before).
- The gesetze-normen seed object no longer re-uploads on every `apply`: `aws_s3_object` compares `source_hash` instead of the ETag, which under SSE-KMS is not the content MD5 (plan showed a permanent etag diff).

### Changed
- Upstream submodule bumped from 06019d4 (v0.2.1+37) to the release tag **v0.2.3** (7829126, 2026-10-12). No change to the Helm charts, the Keycloak bootstrap, the frontend routing contract or the seed scripts between the two commits; the overlay only gains per-service image tags.
- Overlay pins `image.tag: v0.2.3` for the 12 services with a published 0.2.3 image (frontend, document-management-service, agent-orchestration-service, administrative-file-draft, comment-service, examination-service, feedback-service, formal-completeness-check, fpp-service, identity-management-service, objections-management-service, plausibility-notes); the other 18 stay on the chart default `v0.2.1` because the registry publishes no 0.2.3 image for them (README section E, tag matrix). Static check: `helm template` through the postrenderer renders 105 resources unchanged apart from the tags. Verified live 2026-10-20 with `make apply` from zero: verify.sh 6/6, scripted OIDC login, ZIP upload via presigned URLs, formal completeness check completed with 74 Bedrock invocations, seed runner `All seeds completed.` on the ZenDiS minimal images (README section E).
- `.terraform.lock.hcl` additionally carries the `linux_arm64` provider hashes (same provider versions; `terraform init` on an arm64 Linux operator host no longer modifies the tracked lock file).
- README intro names the upstream project by its openCode link and license only; the shared threat model (`docs/THREAT-MODEL.md`) describes the current controls without revision markers or change history.

### Security
- Not covered by this bump (no published image): the upstream 0.2.3 fix for the PII redaction leak (issue #40, `modul-anonymisierung`) and the prompt-schema fix in `modul-formale-pruefung`; both modules stay on `v0.2.1` until the 0.3.0 re-integration. Recorded as THREAT-MODEL B-4.
- Non-production disclaimer in the first screen of the README (and the root README), linking the threat model.
- One customer-managed KMS key per environment (`terraform/modules/kms`, rotation on, 7-day deletion window) now encrypts every Secrets Manager entry, all four S3 buckets (SSE-KMS + Bucket Keys), ElastiCache Valkey at rest, RDS Performance Insights and the exported RDS log groups. The ESO pod identity is limited to `kms:Decrypt` on that key (`external_secrets_kms_key_arns`; the module default is every key in the account), the S3 IAM user receives the matching `kms:GenerateDataKey*`/`Decrypt` so presigned browser uploads keep working.
- S3: versioning on every bucket plus a lifecycle rule (noncurrent versions and abandoned multipart uploads expire after 7 days).
- RDS: CloudWatch log exports (`postgresql`, `upgrade`) into pre-created KMS-encrypted log groups with 365-day retention, Performance Insights (KMS), Enhanced Monitoring (60 s, own service role), IAM database authentication (additive), `copy_tags_to_snapshot`; `deletion_protection` is a variable (`SPARK_WORKFLOW_RDS_DELETION_PROTECTION`, default false for the hands-off destroy).
- EKS public API endpoint now honours `DEMO_ALLOWED_CIDRS` (`cluster_endpoint_public_access_cidrs`; empty = open). Include the operator's own address when setting it.
- Terraform registry modules pinned to the commit of their release tag (vpc v5.21.0, eks v20.37.2, eks-pod-identity v1.12.1); availability zones pinned by name with a count postcondition (`availability_zone_names` override).
- TEI: `BAAI/bge-m3` pinned to a Hub revision (`tei.revision`, `--revision` arg). Platform chart 0.2.0.
- Static review (checkov + semgrep over Terraform/Helm/scripts) brought to zero findings; every remaining trade-off carries an inline `#checkov:skip` / `# nosemgrep` with its reason (single-AZ RDS/Valkey, no secret rotation, no bucket access logging/replication, static S3 keys, demo-grade teardown flags).
- Internal process and tooling references removed from the published tree (DEMO.md access section, Makefile notes, scanner wording in comments and docs).

### Changed
- `demo-data/generate_demo_documents.py`: implicit string-literal concatenation inside the story lists made explicit (`+`); byte-identical constant pool, no output change.
- README: new section F "Data protection and hardening defaults"; operational note on applying the hardening to an environment created before it (ElastiCache is re-created, secrets re-key in place).

### Security (earlier)
- Keycloak admin surface no longer answers from the internet: `/admin/master/**` and `/realms/master/**` return 403 through an `HTTPRouteFilter` `directResponse` on a dedicated `keycloak-admin-denied` HTTPRoute (upstream routes the whole Keycloak host with one catch-all rule). Driven by a security scan of the live deploy. Scope stops short of `/admin` on purpose: identity-management-service reaches the token-protected admin REST API `/admin/realms/<realm>` through the public hostname (`AUTH_BASE_URL`), so a blanket deny breaks `GET /users`. Verified live: console/master 403, `/admin/realms/local/users` 401 unauthenticated, `GET /api/identity/users` 200 through the app, scripted OIDC login green
- Optional source-IP allowlist on the public NLB: `DEMO_ALLOWED_CIDRS` (root `.env`, comma-separated) → `loadBalancerSourceRanges` on the EnvoyProxy `envoyService`, covering all three hostnames and both `:80`/`:443`. Empty = open to the internet (unchanged from-zero default). Route-level OIDC does not clear the finding: the scanner counts the login redirect itself as an unauthenticated response

### Fixed
- protocol-service never became Ready (readiness 503 for hours, pod counted as Running): the chart renders all nine per-source `*_DB_HOST` envs empty, so no source database was reachable — every source now points at RDS
- verify.sh: readiness-based pod check (a phase check cannot see a failing probe) and per-run kubectl context pinning
- Fully automatic teardown (ported from the spark-api-demo destroy test, same observed failure classes): destroy-order guards k8s_addons→eks and eks→network (node groups/NAT otherwise die in parallel with the helm uninstalls — orphaned Envoy NLB, frozen ExternalSecret finalizers, leaked EBS volumes, LB controller cut off from the AWS APIs), namespaces→ESO (hook ExternalSecrets survive helm uninstall and need ESO alive for their cleanup finalizer), envoy-gateway→LB-controller (NLB cleanup needs the controller); LBC service mutator webhook disabled (failurePolicy=Fail races controller readiness on bring-up)
- verify.sh ExternalSecrets check: readiness via jsonpath (ESO CRD column layout drift flagged every synced secret as not synced)

### Added
- README: TL;DR/executive summary, "why built this way" rationale, Mermaid architecture diagram with the OSS-blue / AWS-orange color legend and upstream-vs-demo (dashed) distinction
- `DEMO.md`: demo script with CLI and console workflows per component (EKS access from the laptop, frontend login from Secrets Manager, UI walkthrough, RDS/S3/Valkey/Secrets/LiteLLM+Bedrock/TEI/Temporal/Qdrant/Keycloak/SpiceDB/Envoy/DNS/TLS, troubleshooting, teardown)

### Added
- Seed jobs are parameterized: `SPARK_WORKFLOW_SEED_JOBS_ENABLED` in `.env` (default true) → `seed_jobs_enabled` Terraform variable → chart `enabled` flag
- README "Users & roles" section + DEMO.md how-to for adding users (upstream-intended way: Keycloak admin console, realm roles `user`/`admin`), based on an audit of the upstream identity model (`bootstrap.sh`, `authentification` lib, identity-management-service)

### Fixed
- Document extraction always failed ("All N chunk(s) failed extraction (including fallbacks)" in the docling-extraction workflow, including split/raster fallbacks): the demo overlay pointed the extraction worker and the gesetzesbegruendung-db-service at docling on port 5001 — that is the pod targetPort; the docling-rq Service only exposes port 80 (nothing is programmed for 5001 on the ClusterIP, so every submit ran into ConnectTimeout). Now on the Service port 80, matching the upstream env defaults. Verified: connect test from the worker pod (:80 OK, :5001 timeout), then a live re-run — docling-serve accepts the submit, converts (RQ job OK), and the `docling-extraction` workflow completes. The subsequent VLM enhancement stage is a separate, newly reachable gap (see Known issues)

### Added
- `demo-data/`: synthetic sample upload `antragsunterlagen-ortsumgehung-musterhausen.zip` for the AI-analysis demo — a fictional plan approval procedure ("Ortsumgehung Musterhausen (B 999n)") with two German PDFs (Erläuterungsbericht with traffic/technical tables and a site-plan figure; Umweltbericht Kurzfassung with species/measures tables and a noise-level chart), deliberately covering the extraction, table/vision-VLM, species and metadata-keyword paths; every page carries a synthetic-data disclaimer. Reproducible via `demo-data/generate_demo_documents.py` (reportlab); referenced in DEMO.md §2

### Changed
- Bedrock moved to `eu-central-1` (default `BEDROCK_REGION`): `gpt-oss-120b` is now available on-demand in Frankfurt, so chat/reasoning, the new vision model, and the in-cluster TEI embeddings all run in the EU geography. `.env.example` updated; the LiteLLM Pod Identity policy is now geo-scoped (foundation models of the `BEDROCK_REGION` geography + inference profiles, required for cross-region profile routing)

### Fixed
- Documents failed after successful extraction: the VLM enhancement stage (`vlm-batch-processing`) sends image content blocks, but the upstream default `VLLM_MODEL=self-hosted/gpt-oss-120b` is text-only — Bedrock rejected every element (400 "This model doesn't support the image content block"); there is no upstream flag to skip the stage and the single-document workflow treats its failure as fatal. LiteLLM now additionally serves `self-hosted/pixtral-large` → Bedrock `eu.mistral.pixtral-large-2502-v1:0` (EU cross-region profile, the only weights-available vision model in the EU profiles; configurable via `BEDROCK_VLM_MODEL_ID`), and the overlay points `VLLM_MODEL` at it (platform chart 0.1.6). Verified end to end: fresh run after `temporal workflow reset` — extraction, `vlm-batch-processing` and `single-document-workflow` all COMPLETED; CloudWatch shows the Pixtral invocations in `eu-central-1`. Note for in-flight runs: scheduled activities bake the model name into their input, so runs started before the rollout keep failing until reset/retried
- Browser uploads failed ("Hochladen fehlgeschlagen") — two independent causes, both required:
  1. Server-side: with ClamAV enabled the DMS service issues presigned upload URLs against the **quarantine** bucket, which had no CORS rule — the browser would block the direct PUT. The frontend-origin CORS rule now covers dms and quarantine (terraform s3 module, `moved` block preserves the existing dms rule). Verified end to end with session login: generate-upload-url → OPTIONS preflight 200 → PUT 200 with correct Access-Control-Allow-Origin
  2. Client-side: the SPA validates presigned URLs against runtime allowlists before sending anything (`VITE_ALLOWED_UPLOAD_ORIGINS`/`VITE_ALLOWED_DOWNLOAD_ORIGINS`, see upstream `uploadUrlSafety.ts`) — unset, every upload was rejected in the browser before any request (DMS logs showed successful generate-upload-url but never a confirm). Both now set to the regional S3 endpoint in the frontend values; verified the rolled pod serves them in the app config
- `GET /api/identity/users` returned 500 ("OIDC token request failed"): the identity-management-service was missing `AUTH_CLIENT_ID` for its admin-API client-credentials flow (the shared lib does not fall back to `AUTH_AUDIENCE`); now wired alongside `AUTH_CLIENT_SECRET`, matching the upstream chart's values contract. Verified: /users returns the demo user
- Empty lookup tables broke the UI ("Verfahrensarten konnten nicht geladen werden" — `/api/pls/v1/project-types` returned `[]`): the upstream lookup-data seeds only exist in the process-compose dev setup, not in the Helm charts. New `helm/seed-jobs` chart runs the idempotent upstream seeds (project-logic-service, formal-completeness-check, administrative-file-draft) inside the running service pods after every umbrella change; deployed as its own release after the umbrella. Verified: all three seeds complete, project types load
- Blank SPA page (all `/app/assets/*` 404): added the `frontend-app` HTTPRoute that strips the `/app` prefix before the frontend nginx (frontend serves from the web root while index.html references `/app/...`; a separate route because HTTPRoutes allow at most 16 rules). Verified post-login: index.html plus all 33 referenced assets return 200 with correct MIME types (platform chart 0.1.5)
- Temporal UI login ("OAuth flow failed"): split the OIDC SecurityPolicy into one policy per host (`frontend-oidc`, `temporal-oidc`) — `redirectURL` must match the originating host, since Envoy's oauth2 filter sets CSRF/session cookies bound to the host; the Keycloak bootstrap now registers the redirect URIs/WebOrigins of both hosts (platform chart 0.1.4). E2E-verified on both hosts

## [0.1.0] — 2026-08-19

First fully verified demo environment: `make apply` through to a running
application. E2E-verified: OIDC login → SPA, `/api/identity/me` with a
verified JWT, Bedrock chat (`gpt-oss-120b`) and TEI embeddings (`BGE-M3`)
via LiteLLM, Temporal/Qdrant/SpiceDB/Docling/ClamAV in operation.

### Added
- Upstream umbrella deployment fully wired up: demo values template (`helm/values/spark-workflow.demo.yaml.tftpl`) fills all placeholders of the 00-spark-workflow suite (DB/S3/auth/LLM/CORS per service); rendering verified end-to-end (terraform templatefile → helm template, 107 resources); API gateway routing (15 path rules with prefix rewrite) derived from the frontend contract; perimeter login via Envoy Gateway OIDC SecurityPolicy; 26 app secrets via ExternalSecrets; `normenermittlung` module disabled (no public upstream image in v0.2.1)
- Terraform foundation (validated via `terraform validate`): VPC/networking, EKS (node pools default/qdrant/gpu-optional, Pod Identity, EBS CSI), RDS PostgreSQL 16 (pgvector-ready), S3 (dms/temporal-payloads/temporal-archival/quarantine incl. CORS + scoped IAM user), ElastiCache Valkey (flag, TLS+AUTH), secrets generation into AWS Secrets Manager
- Cluster addons via Terraform/Helm: aws-load-balancer-controller, External Secrets Operator (+ClusterSecretStore), cert-manager (+Let's Encrypt DNS-01 issuer, SAN certificate), external-dns (Gateway API sources), Envoy Gateway (+GatewayClass/Gateway behind NLB), metrics-server, gp3 default StorageClass
- Pod Identity role for LiteLLM→Amazon Bedrock access (`gpt-oss-120b`, region configurable)
- Makefile workflow with `.env` integration (root `.env` untracked; `.env.example` with placeholder values); sizing fully parameterized
- Project structure created; upstream SPARK Workflow included as a Git submodule (as of: main / v0.2.1 images)
- README, LICENSE (MIT-0), THIRD_PARTY_NOTICES

# SPARK Workflow on EKS — Demo Script

This document contains the CLI and console workflows for presenting the running
demo component by component. All commands run from the laptop; no values are
hardcoded — everything comes from the root `.env` or is queried live from
AWS/Kubernetes.

> Prerequisite: The deployment is running (see [README](README.md)). The demo
> costs money while it runs — don't forget the teardown at the end.

---

## 0. Set Up Access (once per working day)

The demo expects short-lived AWS credentials for the profile named in
`.env` (`AWS_PROFILE`). Renew them the way your organization issues them
(for example `aws sso login --profile "$AWS_PROFILE"`), then test:

```bash
set -a; source .env; set +a
aws sts get-caller-identity
```

### Generate kubectl Access to EKS

The cluster uses EKS access entries; the role that ran Terraform
(cluster creator) automatically has admin access. Generate the kubeconfig:

```bash
set -a; source .env; set +a
aws eks update-kubeconfig \
  --name "${PROJECT_PREFIX}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --alias "${PROJECT_PREFIX}"

# Test: who am I in the cluster, and is everything running?
kubectl auth whoami
kubectl get nodes
kubectl get pods -A | grep -vc Running   # number of non-running pods (target: 1 = header line)
```

The command is idempotent — on "Unauthorized" simply renew the AWS
credentials; the kubeconfig itself stays valid (it generates tokens on the
fly via `aws eks get-token`).

### Session Variables for All Following Sections

Every demo session starts with this block (in the repo root):

```bash
set -a; source .env; set +a
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export APP_URL="https://${SPARK_WORKFLOW_HOST}.${BASE_DOMAIN}"
export AUTH_URL="https://${KEYCLOAK_HOST}.${BASE_DOMAIN}"
export TEMPORAL_URL="https://${TEMPORAL_HOST}.${BASE_DOMAIN}"
echo "App:      ${APP_URL}/app/"
echo "Keycloak: ${AUTH_URL}"
echo "Temporal: ${TEMPORAL_URL}"
```

---

## 1. Frontend Login

The demo credentials (Keycloak user in the `local` realm) live in AWS Secrets
Manager — nowhere in Git:

```bash
aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_PREFIX}/auth/keycloak" \
  --query SecretString --output text | jq .
```

| Field | Meaning |
|---|---|
| `demo_user_email` / `demo_user_password` | Login for the SPA at `${APP_URL}/app/` |
| `admin_password` | Keycloak admin (`admin`) at `${AUTH_URL}` |
| `client_id` / `client_secret` | OIDC client `local-client` (for API tokens via CLI) |

**Console path:** AWS Console → Secrets Manager → `spark-demo/auth/keycloak` →
"Retrieve secret value".

---

## 2. Demo Script (UI Walkthrough)

### What you are demoing (version & maturity)

Useful context when the audience asks "what exactly is this?":

- **SPARK Workflow** (openCode / BMDS, EUPL-1.2) — AI-assisted processing of
  plan approval procedures (Planfeststellungsverfahren). Charts and config in
  this demo come from upstream `main` at commit `06019d4` (2026-08-11,
  37 commits after the `v0.2.1` tag); the deployed **container images are
  `v0.2.1`** — the newest published release images.
- This is an **early-stage product**: the UI covers procedure work (create,
  upload, AI analysis, results); user management, roles administration, and
  approval workflows are on the upstream roadmap (`docs/roadmap.md`), not in
  the app yet. Users live in Keycloak, master data is API-managed (see §11).
- Two upstream modules are disabled in this demo because v0.2.1 ships no
  images for them (`normenermittlung`, `landingpage`); flows that depend on
  the proprietary Pharia Document Index are a documented functional gap.
- Upstream ships a German user manual and product brief in the submodule:
  `spark-workflow/docs/Benutzerhandbuch_GER_v1.pdf` and
  `Technischer_Produktsteckbrief_GER_v1.pdf`, plus feature lists
  (`docs/feature-list-en.md`).
- What the seeds provide: **lookup data only** (procedure types, status
  values, checklist templates) — no sample procedures. An empty procedure
  list after login is expected; creating the first procedure is part of the
  demo.

The storyline for the presentation — duration approx. 10–15 minutes:

1. **Login:** Open `${APP_URL}/app/` → Envoy Gateway redirects to Keycloak
   (OIDC) → sign in with `demo_user_email`/`demo_user_password` → back to the SPA.
2. **Create a procedure:** Create a new procedure (project) — shows
   `project-lifecycle-service` + RDS persistence.
3. **Upload application documents:** Upload a ZIP with PDFs — the upload passes
   through the ClamAV virus scan (quarantine bucket) and lands in the DMS bucket (S3).
   Ready-made synthetic sample: `demo-data/antragsunterlagen-ortsumgehung-musterhausen.zip`
   (fictional bypass-road procedure; explanatory + environmental report with German
   text, tables, and figures — exercises extraction, table/vision VLM, species and
   metadata paths; regenerate via `demo-data/generate_demo_documents.py`).
4. **Start AI analysis:** Trigger the analysis — Temporal workflows orchestrate
   the AI modules; LLM calls go via LiteLLM to Amazon Bedrock in
   `eu-central-1` (`gpt-oss-120b` for text, Pixtral Large for images/tables
   in the extraction pipeline), embeddings to the in-cluster TEI (BGE-M3),
   vectors to Qdrant.
5. **Show in parallel:** Temporal UI (`${TEMPORAL_URL}`) — the same analysis as
   running workflows with event history. This makes the orchestration visible;
   follow the presenter walkthrough in §9 (filter `Running`, open a workflow,
   event history) and optionally the live Bedrock graph from §8.
6. **Result:** Walk through the analysis results/extractions in the procedure.

Sections 3–12 below are the "under-the-hood" segments you can weave in
depending on the audience.

---

## 3. EKS Cluster & Workload Topology

**Story:** ~75 app pods, organized by the upstream project's architecture
layers; plus a platform layer (Keycloak, LiteLLM, TEI) and cluster addons.

```bash
# Cluster & nodes (Graviton, private subnets)
kubectl get nodes -o wide
aws eks describe-cluster --name "${PROJECT_PREFIX}" \
  --query 'cluster.{version:version,endpoint:resourcesVpcConfig.endpointPublicAccess,platform:platformVersion}'

# The four architecture layers of the upstream project (labels from the umbrella chart)
kubectl get pods -n spark -L spark-workflow.layer/name --sort-by='.metadata.labels.spark-workflow\.layer/name'

# Summary: pods per layer
kubectl get pods -n spark -o jsonpath='{range .items[*]}{.metadata.labels.spark-workflow\.layer/name}{"\n"}{end}' | sort | uniq -c

# Domain groups (Beschlussdienste, Workflow-Dienste, ...)
kubectl get pods -n spark -L spark-workflow.group/name --no-headers | awk '{print $NF}' | sort | uniq -c

# Platform layer & addons
kubectl get pods -n spark-platform
for ns in envoy-gateway-system cert-manager external-secrets external-dns spicedb-operator; do
  echo "--- $ns"; kubectl get pods -n "$ns" --no-headers
done
```

**Console path:** EKS → cluster `spark-demo` → "Resources" tab → Pods
(namespace filter `spark`), "Compute" tab for the node groups (default +
`qdrant` group, pinned to one AZ because of EBS).

---

## 4. RDS PostgreSQL (one instance, many databases)

**Story:** A single RDS PostgreSQL 16 (`db.r6g.xlarge`, Graviton) carries all
service databases plus Keycloak, Temporal, and SpiceDB — provisioned by
Terraform, schemas/seeds from the upstream chart.

```bash
# Show the instance
aws rds describe-db-instances --db-instance-identifier "${PROJECT_PREFIX}" \
  --query 'DBInstances[0].{Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,Endpoint:Endpoint.Address,MultiAZ:MultiAZ,Storage:AllocatedStorage}'

# psql session from inside the cluster (RDS is private, no public access)
RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier "${PROJECT_PREFIX}" --query 'DBInstances[0].Endpoint.Address' --output text)
PGPASS=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_PREFIX}/rds/app" --query SecretString --output text | jq -r .password)
PGUSER=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_PREFIX}/rds/app" --query SecretString --output text | jq -r .username)

kubectl run psql-demo --rm -it --restart=Never -n spark \
  --image=postgres:16 --env="PGPASSWORD=${PGPASS}" -- \
  psql -h "${RDS_HOST}" -U "${PGUSER}" -d gesetze_normen

# Worth seeing at the psql prompt:
#   \l                                  -- all databases (one per service)
#   \dt                                 -- 15 tables of the norms service
#   select count(*) from norm;          -- seeded law/norm data
```

**Console path:** RDS → Databases → `spark-demo` → Monitoring (connections
~50+, since all services are connected).

---

## 5. S3 (Documents, Quarantine, Temporal Archival)

**Story:** Four buckets: DMS (documents), quarantine (virus scan intake),
Temporal archival/payloads. The app talks to S3 natively via presigned URLs.

```bash
aws s3 ls | grep "${PROJECT_PREFIX}"

# After an upload in the UI: show the document in the DMS bucket
aws s3 ls "s3://${PROJECT_PREFIX}-${ACCOUNT_ID}-dms/" --recursive --human-readable | tail -20

# Generate a presigned URL (this is how the app delivers documents to the browser)
KEY=$(aws s3api list-objects-v2 --bucket "${PROJECT_PREFIX}-${ACCOUNT_ID}-dms" --query 'Contents[0].Key' --output text)
aws s3 presign "s3://${PROJECT_PREFIX}-${ACCOUNT_ID}-dms/${KEY}" --expires-in 300
```

**Console path:** S3 → filter buckets by `spark-demo` → click into the DMS
bucket, show the object structure.

---

## 6. ElastiCache Valkey (Cache & Sessions)

**Story:** Valkey (open-source Redis fork) as a managed service — TLS +
AUTH token, used by the services as a cache.

```bash
aws elasticache describe-replication-groups --replication-group-id "${PROJECT_PREFIX}" \
  --query 'ReplicationGroups[0].{Engine:Engine,Endpoint:NodeGroups[0].PrimaryEndpoint,TLS:TransitEncryptionEnabled,Auth:AuthTokenEnabled}'

# Live test from the cluster (connection URI with TLS+token is in Secrets Manager)
VK_URI=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_PREFIX}/valkey" --query SecretString --output text | jq -r .uri)

kubectl run valkey-demo --rm -it --restart=Never -n spark --image=redis:7 -- \
  redis-cli -u "${VK_URI}" --no-auth-warning INFO server
# Worth seeing: redis-cli ... DBSIZE   and   KEYS '*' (demo scope, never use KEYS in prod)
```

**Console path:** ElastiCache → Valkey caches → `spark-demo`.

---

## 7. Secrets Manager + External Secrets Operator

**Story:** No secret lives in Git or in Helm values. Terraform generates
random values into Secrets Manager; the External Secrets Operator syncs them
into the cluster as Kubernetes secrets (IRSA/Pod Identity, no static key).

```bash
# The secret family in AWS
aws secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name, '${PROJECT_PREFIX}/')].Name" --output table

# ESO: sync status in the cluster (SecretSynced=True)
kubectl get externalsecrets -A
kubectl get clustersecretstore -o wide

# Proof: the K8s secret is a copy from Secrets Manager
kubectl get secret -n spark -o name | head
```

**Console path:** Secrets Manager → filter `spark-demo/` → open a secret →
"Retrieve secret value".

---

## 8. LiteLLM → Amazon Bedrock (LLM) + TEI (Embeddings)

**Story:** The app only talks to an OpenAI-compatible endpoint (upstream model
names `self-hosted/...` remain unchanged). Behind it, LiteLLM routes chat to
Bedrock `gpt-oss-120b` (OSS weights, on-demand in `eu-central-1`, Pod
Identity — no keys), the vision stage of the extraction pipeline to Bedrock
Pixtral Large (`eu.` cross-region profile — inference stays in the EU
geography), and embeddings to an in-cluster TEI with BGE-M3.

```bash
LLM_KEY=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_PREFIX}/llm/litellm" --query SecretString --output text | jq -r .master_key)
kubectl port-forward -n spark-platform svc/litellm 4000:4000 >/dev/null 2>&1 &
sleep 2

# Which models does the app see?
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer ${LLM_KEY}" | jq '.data[].id'

# Chat → goes to Amazon Bedrock (gpt-oss-120b)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LLM_KEY}" -H 'Content-Type: application/json' \
  -d '{"model":"self-hosted/gpt-oss-120b","messages":[{"role":"user","content":"Name the 3 core steps of a plan approval procedure, one sentence each."}]}' \
  | jq -r '.choices[0].message.content'

# Vision → Bedrock Pixtral Large via the EU cross-region profile
# (the model behind the VLM enhancement stage; a 1x1 pixel as smoke test)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LLM_KEY}" -H 'Content-Type: application/json' \
  -d '{"model":"self-hosted/pixtral-large","max_tokens":60,"messages":[{"role":"user","content":[{"type":"text","text":"What do you see? One short sentence."},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}}]}]}' \
  | jq -r '.choices[0].message.content'

# Embeddings → in-cluster TEI (BGE-M3, 1024 dimensions)
curl -s http://localhost:4000/v1/embeddings \
  -H "Authorization: Bearer ${LLM_KEY}" -H 'Content-Type: application/json' \
  -d '{"model":"self-hosted/bge-m3","input":"approval procedure"}' \
  | jq '{model, dim: (.data[0].embedding | length)}'

kill %1 2>/dev/null  # stop the port-forward
```

### Watching Bedrock live during an AI analysis

While an analysis runs, prove the calls are real from three angles:

```bash
# 1) Every LLM/embedding request the AI modules make (stream):
kubectl logs -n spark-platform deploy/litellm -f | grep -E "chat/completions|embeddings"

# 2) Bedrock invocations from the AWS side (BEDROCK_REGION, default eu-central-1):
aws cloudwatch get-metric-statistics --region "${BEDROCK_REGION}" \
  --namespace AWS/Bedrock --metric-name Invocations \
  --dimensions Name=ModelId,Value=openai.gpt-oss-120b-1:0 \
  --start-time "$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 300 --statistics Sum --output table
# Same for the vision model of the extraction pipeline (VLM stage):
#   --dimensions Name=ModelId,Value=eu.mistral.pixtral-large-2502-v1:0
# Also nice: --metric-name InputTokenCount / OutputTokenCount / InvocationLatency
```

**3) Console (the money shot):** region `${BEDROCK_REGION}` → CloudWatch →
Metrics → Bedrock → "By ModelId" → `openai.gpt-oss-120b-1:0` → Invocations,
1-minute period, line chart. Put the app with the running analysis on one
screen and this live-climbing graph next to it. (Reference: a single-ZIP
analysis produced ~400–500 invocations per 5 minutes.)

**Console path:** Bedrock (region `${BEDROCK_REGION}`) → Model access →
`openai.gpt-oss-120b` and `Pixtral Large (25.02)` enabled.

---

## 9. Temporal (Workflow Orchestration)

**Story:** Every AI analysis is a Temporal workflow — visible, repeatable,
with event history. This is the best "under the hood" view for an audience:
it shows WHAT the AI modules are doing while the app UI just says "running".

**Login:** `${TEMPORAL_URL}` — same OIDC login as the frontend
(`demo_user_email`/`demo_user_password`); if you are already signed in to the
app, Keycloak SSO usually lets you straight through.

**Walkthrough to present (after starting an AI analysis, §2 step 4/5):**

1. **Workflows** (left nav) → set the query filter to
   `ExecutionStatus="Running"` — during an analysis expect a couple dozen
   entries. The type names ARE the domain story, call them out:
   `docling-extraction` (PDF content extraction),
   `FVPWorkflow`/`MVPWorkflow` (formal/material completeness checks),
   `LoadNormWorkflow` (loading laws/norms), `RechtsmethodikWorkflow`
   (legal-methodology analysis), `TatbestandsAnalyseWorkflow`,
   `PruefFormulierungsAgentWorkflow` (drafting agent).
2. Open one running workflow → **Event History**: activities, inputs,
   retries; **Pending Activities** shows what it is waiting on right now.
   Each LLM call in here is a Bedrock invocation (pair this with the
   CloudWatch graph from §8 on a second screen).
3. When the analysis finishes, flip the filter to
   `ExecutionStatus="Completed"` — the same list, now done; results appear
   module by module in the app.

```bash
# CLI view of the same stack (no temporal CLI needed — the UI's own API):
kubectl get pods -n spark -l 'app.kubernetes.io/name=temporal'
kubectl port-forward -n spark svc/spark-temporal-web 18080:8080 >/dev/null 2>&1 &
sleep 2
# Count + types of running workflows:
curl -s 'http://localhost:18080/api/v1/namespaces/default/workflows?query=ExecutionStatus%3D%22Running%22' \
  | jq -r '.executions[].type.name' | sort | uniq -c | sort -rn
kill %1 2>/dev/null

# Alternative with the temporal CLI (brew install temporal):
# kubectl port-forward -n spark svc/spark-temporal-frontend 7233:7233 &
# temporal workflow list --address localhost:7233
```

---

## 10. Qdrant (Vector Database)

**Story:** Semantic search over the uploaded documents — BGE-M3 vectors live
in Qdrant (in-cluster, dedicated node group with EBS volumes).

> Collections only appear once the first AI analysis has processed documents —
> so show this section after step 4 of the script.

```bash
kubectl port-forward -n spark svc/spark-qdrant 6333:6333 >/dev/null 2>&1 &
sleep 2
curl -s http://localhost:6333/collections | jq '.result.collections[].name'
# Details of a collection (vector size 1024 = BGE-M3):
C=$(curl -s http://localhost:6333/collections | jq -r '.result.collections[0].name')
curl -s "http://localhost:6333/collections/${C}" | jq '{name:"'$C'", points:.result.points_count, dim:.result.config.params.vectors}'
kill %1 2>/dev/null
```

Web dashboard: `http://localhost:6333/dashboard` (while the port-forward is running).

---

## 11. Keycloak & SpiceDB (Identity & Authorization)

**Story:** Login via Keycloak (realm `local`, OIDC), permission model via
SpiceDB (Zanzibar model) — both open source, both persisted on RDS.

```bash
# Keycloak admin console
echo "${AUTH_URL}  → Login: admin / $(aws secretsmanager get-secret-value --secret-id ${PROJECT_PREFIX}/auth/keycloak --query SecretString --output text | jq -r .admin_password)"
# Show: realm 'local' → Clients ('local-client') → Users (demo user)

# Get a token via CLI (the same OIDC machinery as the browser login)
KC=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_PREFIX}/auth/keycloak" --query SecretString --output text)
TOKEN=$(curl -s "${AUTH_URL}/realms/local/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=local-client \
  -d client_secret="$(echo "$KC" | jq -r .client_secret)" \
  -d username="$(echo "$KC" | jq -r .demo_user_email)" \
  -d password="$(echo "$KC" | jq -r .demo_user_password)" | jq -r .access_token)

# Use it directly against the API (through Envoy):
curl -s "${APP_URL}/api/identity/me" -H "Authorization: Bearer ${TOKEN}" | jq .
curl -s "${APP_URL}/api/pls/v1/projects" -H "Authorization: Bearer ${TOKEN}" | jq '. | length'

# SpiceDB is running and attached to RDS:
kubectl get pods -n spark -l 'app.kubernetes.io/instance=spark-spicedb'
kubectl get spicedbcluster -n spark 2>/dev/null || true
```

### Adding a user (the upstream-intended way)

Upstream manages users directly in Keycloak (no in-app user management yet).
In the admin console (`${AUTH_URL}`, login `admin`):

1. Realm `local` → Users → **Create user**: set username = email, fill
   email, mark **Email verified** → Create.
2. Tab **Credentials** → Set password (temporary off).
3. Tab **Role mapping** → Assign role → filter "Realm roles" → assign
   `user` (and `admin` for admin capabilities — audit log, project
   deletion, mutation of any project).

The new login works immediately; the app lists the user via its
`/api/identity/users` endpoint (backed by the Keycloak admin API).

### Managing master data (procedure types) via API

There is no admin UI for master data — upstream manages it through the
service REST APIs (full bulk CRUD, `admin` role required). The UI consumes
the result in the "create procedure" dialog. From the laptop, talk to the
service directly via port-forward (bearer-only calls through the public
hostname would hit the OIDC redirect):

```bash
# Token (same OIDC machinery as the browser; TOKEN as in §11 above)
KC=$(aws secretsmanager get-secret-value --secret-id "${PROJECT_PREFIX}/auth/keycloak" --query SecretString --output text)
TOKEN=$(curl -s "${AUTH_URL}/realms/local/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=local-client \
  -d client_secret="$(echo "$KC" | jq -r .client_secret)" \
  -d username="$(echo "$KC" | jq -r .demo_user_email)" \
  -d password="$(echo "$KC" | jq -r .demo_user_password)" | jq -r .access_token)

kubectl port-forward -n spark svc/spark-project-logic-service 18000:80 >/dev/null 2>&1 &
sleep 2

# List procedure types (what the UI dropdown shows)
curl -s http://localhost:18000/project-types -H "Authorization: Bearer ${TOKEN}" | jq .

# Create one (bulk API; duplicate names are rejected with 409)
curl -s -X POST http://localhost:18000/project-types \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d '[{"name":"Bundeswasserstraße"}]' | jq .

# Rename / delete by id
# curl -s -X PATCH http://localhost:18000/project-types -H "Authorization: Bearer ${TOKEN}" \
#   -H 'Content-Type: application/json' -d '[{"id":"<uuid>","name":"New name"}]' | jq .
# curl -s -X DELETE "http://localhost:18000/project-types?ids=<uuid>" -H "Authorization: Bearer ${TOKEN}"

kill %1 2>/dev/null
```

The same pattern works for the other services' master data (each FastAPI
service exposes Swagger docs at `/docs` through the port-forward). The
initial values come from the automated seed jobs (see README "Users &
roles"); disable them with `SPARK_WORKFLOW_SEED_JOBS_ENABLED=false`.

---

## 12. Ingress Path: Envoy Gateway, DNS, TLS

**Story:** One NLB → Envoy Gateway (Gateway API instead of classic Ingress).
OIDC protection sits as a SecurityPolicy directly on the gateway. external-dns
writes DNS records to Route 53, cert-manager obtains certificates via
Let's Encrypt.

```bash
# Gateway + public NLB
kubectl get gateway -n spark-platform
kubectl get httproute -n spark-platform   # frontend / keycloak / temporal-ui per hostname

# Who is OIDC-protected? (SecurityPolicies on the gateway)
kubectl get securitypolicy -n spark-platform -o custom-columns='NAME:.metadata.name,TARGET:.spec.targetRefs[*].name'

# TLS certificates (Let's Encrypt via cert-manager)
kubectl get certificate -A

# DNS automation (external-dns → Route 53)
kubectl logs -n external-dns deploy/external-dns --tail=5
aws route53 list-resource-record-sets --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --query "ResourceRecordSets[?contains(Name, '${SPARK_WORKFLOW_HOST}')].{Name:Name,Type:Type}" --output table
```

**Console path:** EC2 → Load Balancers (the gateway's NLB) and Route 53 →
hosted zone → the three A/TXT record pairs.

---

## 13. Troubleshooting During the Demo

| Symptom | Cause | Fix |
|---|---|---|
| `Unauthorized` with kubectl/aws | Short-lived AWS credentials expired | Renew the credentials for `$AWS_PROFILE`, repeat the command |
| Browser login loop | Stale OIDC session/cookies | Use a private window |
| `kubectl port-forward` drops | Idle timeout | Simply restart the command |
| Pod "Pending" after node scaling | Capacity | Check `kubectl get nodes`; README § Deviations (node_count) |

## 14. Costs & Teardown

The demo costs roughly €60–70/day (EKS nodes, RDS r6g.xlarge, Valkey, NLB).
After the presentation:

```bash
make -C spark-workflow-demo destroy   # or terraform -chdir=spark-workflow-demo/terraform/envs/demo destroy
```

Rebuild: see [README](README.md) — `make apply` + seeds run automatically;
demo data (uploaded procedures) is gone afterwards.

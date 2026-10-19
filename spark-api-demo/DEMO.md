# SPARK API on EKS — Demo Script

Presenter runbook for the live demo. Commands are copy-paste ready; every
section is independently demoable. Placeholders come from the untracked root
`.env` (`API_HOST` = the public hostname, e.g. `api-suite.<your-domain>`).

Companion docs: [README](README.md) (architecture + deviations),
[CHANGELOG](CHANGELOG.md).

---

## 0. Set Up Access (once per working day)

```bash
# 1) Renew the AWS session, then verify
aws sts get-caller-identity --profile "$AWS_PROFILE"

# 2) kubectl access to the cluster
aws eks update-kubeconfig --name spark-api-demo --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" --alias spark-api-demo

# 3) Everything green?
./scripts/verify.sh
```

### Session variables for all following sections

```bash
export AWS_PROFILE=<profile> AWS_REGION=<region>
BASE="https://$API_HOST"
K="kubectl --context spark-api-demo"
```

---

## 1. Login & Frontend (Genehmigungsportal)

Open `https://$API_HOST` — you land on the **Keycloak login** (the demo's
OSS OIDC perimeter; upstream ships no auth and delegates it to the
demosplan platform, outside demo scope). Credentials:

```bash
aws secretsmanager get-secret-value --secret-id spark-api-demo/auth/keycloak \
  --query SecretString --output text | python3 -m json.tool
# -> demo_user_email / demo_user_password (admin_password = Keycloak console)
```

After login the shell ("Genehmigungsportal") loads with the
microfrontends. Talking point: the login protects the WHOLE host —
frontend, every `/api/*` path, the inspector. `curl` without a session
gets a 302 into the flow:

```bash
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "$BASE/api/kommentar-service/docs"
```

Worth showing in the browser dev tools (Network tab):

- `/env-config.js` — the runtime config contract: `window.ENV` with one
  `*_API_URL` per backend, all pointing at `https://$API_HOST/api/<service>`
  (same-origin path routing, no CORS in play)
- `/mfe-fp/assets/remoteEntry.js` — module federation: each MFE is served
  from a path under the same host

```bash
curl -s "$BASE/env-config.js" | head -25
```

## 2. The demo inspector — watch the API live

The product IS an API; the UI is just one client. The **"API" button**
(bottom right, injected at the demo edge — the upstream frontend image is
untouched) opens the inspector:

- **Tab "API Calls"**: click through the UI and every REST call appears
  live — method, target service, path, status, duration. Narrative: "each
  of these lines is a plain API call you could make with curl."
- **Tab "Backend"**: what happens BEHIND the API:
  - every LLM call the services make (model, tokens, latency) from the
    LiteLLM request log — the badge marks where **Amazon Bedrock** serves
    the model
  - RabbitMQ queues (messages, consumers, publish rate)
  - CloudWatch `AWS/Bedrock` invocation counts — the AWS-side proof

Suggested flow: open the inspector → trigger an AI feature in the UI →
watch the REST call in tab 1, then the Bedrock call appearing in tab 2,
then the CloudWatch counter ticking up.

The same events as raw SSE (nice on a second terminal during the demo):

```bash
# uses your browser session cookie; or port-forward the service directly:
$K port-forward -n spark-api svc/demo-inspector 8000:80 >/dev/null 2>&1 &
sleep 2 && curl -s -N localhost:8000/demo-inspector/events | head -6; kill %1
```

## 2b. The AI check flows — click-through (the demo's core)

All flows below run against the fixed demo Verfahren ("Testverfahren
(Default)") whose documents the seeds provide: a Lageplan and a
Baubeschreibung (fact-dense, with a deliberate contradiction — building
height 12 m vs 15 m — and a missing third document, the
Schallschutzgutachten). Keep the inspector open: every step shows its
REST calls and the LLM calls via LiteLLM → Bedrock.

### Dokumente (mfe-fp) — list, view, upload

- Sidebar "Dokumente": the document list loads from `dokumentensuche`,
  OCR confidence scores from the data-service.
- Click a document → PDF viewer: the PDF is fetched via a presigned S3
  URL (inspector: `GET /documents/{id}/pdf` on the data-service, then the
  browser goes to S3 directly). The "Suche" tab returns a clean empty
  state (no embeddings in the demo index — documented gap).
- Upload: "Dokument hochladen" accepts PDF (Ist-Dokument, type e.g.
  "Antrag") or XLSX (Soll-Dokumente). The PDF text is extracted
  server-side — the created Ist-Dokument carries the extracted
  `markdown_text` (inspector: `POST …/ist-dokumente/create_from_file`,
  201).

### Vollstaendigkeitspruefung (mfe-vp) — the flagship AI run

- Sidebar "Formelle Pruefung → Vollstaendigkeitspruefung": Soll-
  (3 expected) and Ist-Dokumente (2 submitted) render from the seeds.
- "Pruefung starten" → 202; the UI polls `/status` (LAEUFT, progress %)
  — with Claude Haiku the run completes in seconds. Result: 2 of 3
  Soll-Dokumente matched, the Schallschutzgutachten is correctly
  reported missing. From the result, Nachforderungen can be generated
  once the review is completed in the UI.
- Inspector narrative: the model name on the wire is literally
  `<LLM_MODEL>` — the upstream anonymization placeholder, served as a
  real LiteLLM alias (see README deviations).

### Kohaerenzpruefung (mfe-kp) — plausibility + consistency

- Sidebar "Formelle Pruefung → Kohaerenzpruefung", "Pruefung starten":
  two background checks run (Plausibilitaet per document, Konsistenz
  across documents on LLM-extracted facts). Both end in ENTWURF =
  reviewable result; the UI polls every 20 s.
- Expected findings (verified): the Konsistenzpruefung flags the planted
  contradiction — "Gebaeudehoehe weicht zwischen Dokumenten ab" (12 m in
  the Lageplan vs 15 m in the Baubeschreibung, with per-document
  citations) — plus the differing Antragsteller/Bauherr names.
- Facts come from a periodic in-service extraction scheduler (5-min
  interval) — on a fresh deploy the first Konsistenz run may find 0
  facts until the scheduler has passed once (~13 facts per demo
  document afterwards).
- A new run is refused (400) while results sit in ENTWURF — complete
  the review first (the UI's update flow); that is upstream state-machine
  design, not an error.

### Dokumentenschwaerzung (mfe-ws) — redaction

- From the PDF viewer, open a document in the Schwaerzung view (route
  `dokumenten_schwaerzung`): the PDF renders, PII bounding boxes come
  from the orchestrator (`GET /bounding-box-entities/...`, 202 → poll →
  200), saving redactions POSTs back (200, "Storing was successful").

### Materielle Pruefung (mfe-mp)

- Sidebar "Materielle Pruefung": one seeded application card per
  Verfahren renders with approval status.
- Opening a card shows the "no matching jobs" notification (upstream
  semantics: 404 = nothing ran yet). Starting a match runs through
  Antragstyp identification and chunk retrieval, then fails cleanly at
  norm extraction — the legal-norm graph is empty, upstream ships no
  norm data (documented gap). Talking point: the pipeline works; only
  the norm corpus is missing.

### Einwendungsmanagement (sidebar)

- Renders a static explanation page (served by the demo inspector):
  the module is provided by the external demosplan platform upstream
  and is not part of the demo. The Stellungsnahmen/Abschnitte child
  entries are label-only shell routes (upstream design).

### Berichtskonfigurator (mfe-verwaltungsakt) — Bescheid with LLM + PDF

- Sidebar "Berichtskonfigurator": the Bescheid list loads; "Neuen
  Bescheid erstellen" → creates a decision document (201).
- "Generieren": the LLM writes the structured Bescheid document
  (Deckblatt, sections; ~30-60 s). Fallback text "LLM not available"
  would indicate a wiring problem — the demo config routes this to the
  Mistral-family alias.
- PDF export (tex2pdf): renders an 8-page PDF with the neutral demo
  logo (upstream ships none — see deviations).

### Comments & Nachforderungen (shell panels)

- The right sidebar comments work per tab (kommentar-service); the
  Nachforderungen modal lists/creates/updates entries
  (nachforderungen service, note the trailing-slash route).

## 3. The build pipeline (a differentiator of this demo)

SPARK API publishes **no container images** — this demo builds all 24 from
the unmodified submodule:

```bash
# The service inventory (single source of truth)
cat pipeline/services.txt

# ECR: 24 repositories, tags = <git-sha>-p<pipeline-hash>
aws ecr describe-repositories --query 'repositories[].repositoryName' --output table
aws ecr list-images --repository-name spark-api-demo/frontend \
  --query 'imageIds[].imageTag' --output table

# CodeBuild: the batch that built them (24 parallel builds, ~15 min)
aws codebuild list-build-batches-for-project --project-name spark-api-demo-images \
  --sort-order DESCENDING --max-items 1
```

Talking points (details: README section A):
- `pipeline/prepare-context.sh` turns each service dir into a buildable
  context **in CI** — vendored shared libs, generated locks, base-image
  mapping, stubs for files the public repo does not track. The submodule is
  never modified.
- A pipeline change re-tags every image (`-p<hash>`) → reproducible rollouts,
  no `:latest` cache traps.

```bash
# Rebuild + roll everything (idempotent):
./scripts/push-source.sh && make apply
```

## 4. EKS cluster & workload topology

```bash
# Nodes: default amd64 pool + tainted single-AZ pool for stateful workloads
$K get nodes -L dedicated

# 22 backend services + frontend in spark-api
$K get deploy -n spark-api

# Platform: RabbitMQ, Neo4j, Qdrant, LiteLLM, TEI
$K get statefulset,deploy -n spark-api-platform

# The bootstrap jobs that make a fresh install work (README section B)
$K get jobs -n spark-api -n spark-api-platform
```

## 5. RDS PostgreSQL (one instance, 12 service databases)

```bash
aws rds describe-db-instances --db-instance-identifier spark-api-demo \
  --query 'DBInstances[0].{engine:Engine,version:EngineVersion,class:DBInstanceClass,az:AvailabilityZone}'

# psql from inside the cluster (RDS is private)
$K run psql --rm -it --restart=Never -n spark-api-platform \
  --image=public.ecr.aws/docker/library/postgres:16 \
  --env="PGPASSWORD=$($K get secret rds-app -n spark-api-platform -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h "$($K get secret rds-app -n spark-api-platform -o jsonpath='{.data.host}' | base64 -d)" \
  -U spark_app -d dokumentenaufbereitung

# Worth seeing at the prompt:
#   \l                                   -- 12 service databases
#   \dt                                  -- data-service tables (procedure, proposal, ...)
#   select count(*) from procedure;      -- Faker mock data from the seed job
```

## 6. The seeded data through the API (what the UI reads)

```bash
# data-service: procedures/proposals from the mock-data seed
curl -s "$BASE/api/dokumentenaufbereitung-data-service/procedures" | python3 -m json.tool | head -20

# Every FastAPI service self-documents (pick any from env-config.js)
open "$BASE/api/kommentar-service/docs"
open "$BASE/api/subsumtion-service/docs"
```

## 7. RabbitMQ / Neo4j / Qdrant (in-cluster OSS)

```bash
# RabbitMQ: the scaffolding queue the adapters consume (rabbitmq-init)
$K exec -n spark-api-platform rabbitmq-0 -- rabbitmqctl list_queues
$K exec -n spark-api-platform rabbitmq-0 -- rabbitmqctl list_bindings

# Neo4j is answering (graph-api backend)
$K exec -n spark-api-platform neo4j-0 -- cypher-shell \
  -u neo4j -p "$($K get secret neo4j -n spark-api-platform -o jsonpath='{.data.password}' | base64 -d)" \
  "SHOW DATABASES"

# Qdrant collections (vector search)
$K port-forward -n spark-api-platform svc/qdrant 6333:6333 >/dev/null 2>&1 &
sleep 2 && curl -s localhost:6333/collections | python3 -m json.tool; kill %1
```

## 8. Secrets Manager + External Secrets Operator

```bash
# The generated secret family (never in git, never typed by hand)
aws secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name,'spark-api-demo/')].Name" --output table

# ESO sync status — everything SecretSynced=True
$K get externalsecrets -A
```

## 9. LiteLLM → Amazon Bedrock + TEI (the LLM path)

```bash
# The models the services see — EXACTLY the upstream names
LITELLM_KEY=$($K get secret litellm -n spark-api-platform -o jsonpath='{.data.master_key}' | base64 -d)
$K port-forward -n spark-api-platform svc/litellm 4000:4000 >/dev/null 2>&1 &
sleep 2
curl -s localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_KEY" | python3 -m json.tool

# Chat → Amazon Bedrock (Pod Identity, no API keys anywhere)
curl -s localhost:4000/v1/chat/completions -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"self-hosted/gpt-oss-120b","messages":[{"role":"user","content":"One sentence: what is a permit procedure?"}]}' \
  | python3 -m json.tool | head -20
kill %1

# Bedrock invocations from the AWS side
aws cloudwatch get-metric-statistics --namespace AWS/Bedrock --metric-name Invocations \
  --dimensions Name=ModelId,Value=openai.gpt-oss-120b-1:0 \
  --start-time "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum
```

## 10. Ingress & TLS (one host, path routing)

```bash
# One NLB, one certificate, ~30 routes
$K get ingress -n spark-api
$K get certificate -n spark-api

# external-dns manages the record, cert-manager the Let's Encrypt cert
curl -sv "$BASE/" -o /dev/null 2>&1 | grep -E "subject:|issuer:"
```

## 11. Repeatability (the core claim)

```bash
# The whole stack from zero:
#   make apply && ./scripts/push-source.sh && <wait for batch> && make apply
# Idempotent: re-running any step is safe. Prove convergence:
./scripts/verify.sh
```

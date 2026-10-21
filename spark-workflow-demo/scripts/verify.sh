#!/usr/bin/env bash
# =============================================================================
# spark-workflow-demo — deployment verification
# Checks whether the demo is ready after `make apply`.
# Usage:  ./scripts/verify.sh   (reads ../.env for AWS_PROFILE/REGION)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT_DIR/.env" ] && set -a && source "$ROOT_DIR/.env" && set +a

APP_NS="${APP_NS:-spark}"
PLATFORM_NS="${PLATFORM_NS:-spark-platform}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
FAILURES=0

CLUSTER_NAME=$(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw cluster_name)
FRONTEND_URL=$(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw frontend_url)
KEYCLOAK_URL=$(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw keycloak_url)

bold "1/6 kubeconfig"
# Pin the context per invocation: update-kubeconfig also switches the
# CURRENT context, so a second verify run (other cluster) would
# silently redirect this one's kubectl calls.
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --alias "$CLUSTER_NAME" > /dev/null
kubectl() { command kubectl --context "$CLUSTER_NAME" "$@"; }
ok "Cluster $CLUSTER_NAME"

bold "2/6 Nodes & addons"
kubectl get nodes --no-headers | awk '{print "  node:", $1, $2}'
for deploy in \
  "kube-system/aws-load-balancer-controller" \
  "external-secrets/external-secrets" \
  "cert-manager/cert-manager" \
  "envoy-gateway-system/envoy-gateway" \
  "external-dns/external-dns"; do
  ns="${deploy%%/*}"; name="${deploy##*/}"
  if kubectl -n "$ns" rollout status deploy/"$name" --timeout=120s > /dev/null 2>&1; then
    ok "$deploy"
  else
    fail "$deploy not ready"
  fi
done

bold "3/6 ExternalSecrets synced"
# Ready via jsonpath — the printed column layout differs between ESO CRD
# versions (observed: column 5 is REFRESH INTERVAL, column 4 the store, so
# synced secrets were flagged as failed).
NOT_READY=$(kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk '$2 != "True" {print $1}' | head -5 || true)
if [ -z "$NOT_READY" ]; then ok "all ExternalSecrets synced"; else fail "not synced: $NOT_READY"; fi

bold "4/6 Platform (Keycloak, LiteLLM, TEI, SpiceDB)"
for deploy in keycloak litellm tei spicedb; do
  if kubectl -n "$PLATFORM_NS" rollout status deploy/"$deploy" --timeout=300s > /dev/null 2>&1; then
    ok "$PLATFORM_NS/$deploy"
  else
    fail "$PLATFORM_NS/$deploy not ready"
  fi
done

bold "5/6 SPARK Workflow pods ($APP_NS)"
TOTAL=$(kubectl -n "$APP_NS" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
# READY, not just Running: a pod can run for hours with a failing
# readiness probe and a phase-based check never notices.
NOT_READY=$(kubectl -n "$APP_NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk '$2 != "Succeeded" && $3 != "True" {print $1}' || true)
if [ "$TOTAL" -gt 0 ] && [ -z "$NOT_READY" ]; then
  ok "$TOTAL pods Ready/Completed"
else
  fail "pods not Ready: $(echo "$NOT_READY" | head -5 | tr '\n' ' ')"
fi
# 0.3.0: the 15 spark-backend pools share one image; each must report its
# own API_POOL (a pool without it serves nothing) and the three worker
# pools plus the agent modules must poll their Temporal task queues — a
# worker whose first connect was refused keeps its pod Running with no
# poller (README E). Pollers are read from the Temporal frontend.
POOLS=$(kubectl -n "$APP_NS" get deploy -l app.kubernetes.io/part-of=spark-backend --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$POOLS" = "15" ] && ok "15 spark-backend pools deployed" || fail "spark-backend pools: $POOLS (expected 15)"
ADMIN_POD=$(kubectl -n "$APP_NS" get pods -l app.kubernetes.io/component=admintools -o name 2>/dev/null | head -1)
if [ -n "$ADMIN_POD" ]; then
  MISSING=""
  for q in orchestration dms project_logic_service extraction anonymisierung formale-pruefung llm-custom; do
    POLLERS=$(kubectl -n "$APP_NS" exec "$ADMIN_POD" -- temporal task-queue describe --task-queue "$q" --namespace default --output json 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); print(len(d.get("pollers") or d.get("workflowTaskPollers") or []))' 2>/dev/null || echo 0)
    [ "${POLLERS:-0}" -gt 0 ] || MISSING="$MISSING $q"
  done
  [ -z "$MISSING" ] && ok "Temporal pollers on every checked task queue" || fail "no Temporal poller on:$MISSING"
else
  fail "temporal admintools pod not found (poller check skipped)"
fi

bold "6/6 Endpoints"
# A SecurityPolicy Envoy Gateway rejects as Invalid leaves its routes with NO
# policy — every page public (observed: an unsupported field combination,
# /app/ answered 200 to an anonymous request). Read the status, not the fact
# that the object exists.
NOT_ACCEPTED=$(kubectl -n "$PLATFORM_NS" get securitypolicies.gateway.envoyproxy.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}{"\n"}{end}' 2>/dev/null | awk '$2 != "True" {print $1}' || true)
[ -z "$NOT_ACCEPTED" ] && ok "every SecurityPolicy accepted by the gateway" || fail "SecurityPolicy not accepted: $NOT_ACCEPTED"
# Owner-reported 2026-10-20: "400 Request Header Or Cookie Too Large" from the
# frontend nginx and 431 from the pools, because the browser still carried the
# session cookies of earlier deployments (Envoy Gateway suffixes its cookie
# names per SecurityPolicy instance). The gateway verifies the session and
# forwards the token as Authorization; every frontend-host rule must drop the
# Cookie header before the upstream.
KEEPING=$(kubectl -n "$PLATFORM_NS" get httproute frontend frontend-api-v1 frontend-api-v2 -o json 2>/dev/null | python3 -c '
import sys, json
for r in json.load(sys.stdin)["items"]:
    for i, rule in enumerate(r["spec"]["rules"]):
        drops = [h for f in rule.get("filters", []) if f.get("type") == "RequestHeaderModifier" for h in f["requestHeaderModifier"].get("remove", [])]
        if "cookie" not in [h.lower() for h in drops]: print("%s[%d]" % (r["metadata"]["name"], i))' 2>/dev/null || echo "unreadable")
[ -z "$KEEPING" ] && ok "frontend-host routes drop the Cookie header before the upstream" || fail "rules still forwarding cookies: $KEEPING"
for url in "$KEYCLOAK_URL/realms/local/.well-known/openid-configuration" "$FRONTEND_URL"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo "000")
  # Behind OIDC the frontend answers 302 → login; both count as "reachable".
  if [[ "$code" =~ ^(200|302)$ ]]; then ok "$url → $code"; else fail "$url → $code"; fi
done
# The API prefixes of the 0.3.0 contract sit behind the same login: an
# anonymous call must be redirected (302), never answered or 404ed by the
# gateway (a 404 here means the route is missing).
for path in /api/identity/me /api/pls/v1/projects /api/v2/dms/documents /api/temporal/workflows; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$FRONTEND_URL$path" || echo "000")
  [ "$code" = "302" ] && ok "$path → 302 (login)" || fail "$path → $code (expected 302)"
done

echo
if [ "$FAILURES" -eq 0 ]; then
  bold "✅ Demo ready: $FRONTEND_URL"
  echo "   Credentials: $(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw demo_credentials_hint)"
else
  bold "❌ $FAILURES check(s) failed"
  exit 1
fi

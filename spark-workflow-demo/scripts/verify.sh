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

bold "4/6 Platform (Keycloak, LiteLLM, TEI)"
for deploy in keycloak litellm tei; do
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

bold "6/6 Endpoints"
for url in "$KEYCLOAK_URL/realms/local/.well-known/openid-configuration" "$FRONTEND_URL"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo "000")
  # Behind OIDC the frontend answers 302 → login; both count as "reachable".
  if [[ "$code" =~ ^(200|302)$ ]]; then ok "$url → $code"; else fail "$url → $code"; fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  bold "✅ Demo ready: $FRONTEND_URL"
  echo "   Credentials: $(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw demo_credentials_hint)"
else
  bold "❌ $FAILURES check(s) failed"
  exit 1
fi

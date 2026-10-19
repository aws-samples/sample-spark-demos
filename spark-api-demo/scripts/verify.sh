#!/usr/bin/env bash
# =============================================================================
# spark-api-demo — deployment verification
# Checks whether the demo is ready after `make apply` + image builds.
# Usage:  ./scripts/verify.sh   (reads ../.env for AWS_PROFILE/REGION)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT_DIR/.env" ] && set -a && source "$ROOT_DIR/.env" && set +a

APP_NS="${APP_NS:-spark-api}"
PLATFORM_NS="${PLATFORM_NS:-spark-api-platform}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
FAILURES=0

CLUSTER_NAME=$(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw cluster_name)
API_URL=$(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw api_url)

bold "1/6 kubeconfig"
# Pin the context per invocation: update-kubeconfig also switches the
# CURRENT context, so a second verify run (other cluster) would
# silently redirect this one's kubectl calls.
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --alias "$CLUSTER_NAME" > /dev/null
kubectl() { command kubectl --context "$CLUSTER_NAME" "$@"; }
ok "cluster $CLUSTER_NAME"

bold "2/6 Addons"
for deploy in \
  "kube-system/aws-load-balancer-controller" \
  "ingress-nginx/ingress-nginx-controller" \
  "external-secrets/external-secrets" \
  "cert-manager/cert-manager" \
  "external-dns/external-dns"; do
  ns="${deploy%%/*}"; name="${deploy##*/}"
  if kubectl -n "$ns" rollout status deploy/"$name" --timeout=120s > /dev/null 2>&1; then
    ok "$deploy"
  else
    fail "$deploy not ready"
  fi
done

bold "3/6 Platform (RabbitMQ, Neo4j, Qdrant, LiteLLM, TEI)"
for sts in rabbitmq neo4j qdrant; do
  READY=$(kubectl -n "$PLATFORM_NS" get sts "$sts" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${READY:-0}" = "1" ] && ok "$PLATFORM_NS/$sts" || fail "$PLATFORM_NS/$sts not ready"
done
for deploy in litellm tei; do
  if kubectl -n "$PLATFORM_NS" rollout status deploy/"$deploy" --timeout=300s > /dev/null 2>&1; then
    ok "$PLATFORM_NS/$deploy"
  else
    fail "$PLATFORM_NS/$deploy not ready"
  fi
done

bold "4/6 ExternalSecrets synced"
# Ready via jsonpath — the printed column layout differs between ESO CRD
# versions (observed: column 5 is REFRESH INTERVAL here, so every row was
# flagged "not synced" while all ExternalSecrets were Ready=True).
NOT_READY=$(kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk '$2 != "True" {print $1}' | head -5 || true)
if [ -z "$NOT_READY" ]; then ok "all ExternalSecrets synced"; else fail "not synced: $NOT_READY"; fi

bold "5/6 SPARK API services ($APP_NS)"
TOTAL=$(kubectl -n "$APP_NS" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
# READY, not just Running: a pod can run for hours with a failing
# readiness probe and a phase-based check never notices.
NOT_READY=$(kubectl -n "$APP_NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk '$2 != "Succeeded" && $3 != "True" {print $1}' || true)
if [ "$TOTAL" -gt 0 ] && [ -z "$NOT_READY" ]; then
  ok "$TOTAL pods Ready/Completed"
else
  fail "pods not Ready: $(echo "$NOT_READY" | head -5 | tr '\n' ' ')"
fi

bold "6/6 Edge (OIDC perimeter)"
# Unauthenticated requests must be redirected into the login flow.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$API_URL" || echo "000")
[[ "$CODE" =~ ^(200|302)$ ]] && ok "$API_URL → $CODE" || fail "$API_URL → $CODE"
AUTH_URL=$(terraform -chdir="$DEMO_DIR/terraform/envs/demo" output -raw auth_url 2>/dev/null || true)
if [ -n "$AUTH_URL" ]; then
  KC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$AUTH_URL/realms/local/.well-known/openid-configuration" || echo "000")
  [ "$KC" = "200" ] && ok "keycloak discovery → 200" || fail "keycloak discovery → $KC"

  # Keycloak admin surface must be denied at the edge (auth-ingress.yaml
  # server-snippet on $uri). --path-as-is keeps curl from normalizing the
  # probe paths itself — the EDGE has to do it. Expected: 403 for every
  # spelling of the admin console / master realm, 401 (token required, NOT
  # 403) for the realm admin REST API that services call, 200 for discovery.
  expect() { # expect <code> <path> <label>
    local want="$1" path="$2" label="$3" got
    got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --path-as-is "$AUTH_URL$path" || echo "000")
    [ "$got" = "$want" ] && ok "$label → $got" || fail "$label → $got (expected $want)"
  }
  expect 403 "/admin/master/console/"                 "admin console denied"
  expect 403 "/admin/master"                          "admin console (no trailing slash) denied"
  expect 403 "/realms/master/protocol/openid-connect/auth?client_id=security-admin-console" "master realm login denied"
  expect 403 "/ADMIN/MASTER/console/"                 "deny is case-insensitive"
  expect 403 "/%61dmin/master/console/"               "percent-encoded path denied"
  expect 403 "/admin/%6daster/console/"               "percent-encoded segment denied"
  expect 403 "//admin/master/console/"                "double-slash path denied"
  expect 403 "/admin//master/console/"                "double-slash inside path denied"
  expect 403 "/realms/local/../master/"               "dot-segment traversal denied"
  expect 401 "/admin/realms/local/users"              "realm admin REST API stays token-protected (401, not 403)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  bold "✅ Demo ready: $API_URL"
else
  bold "❌ $FAILURES check(s) failed"
  exit 1
fi

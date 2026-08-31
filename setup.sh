#!/bin/bash
# Part 1 pre-flight — kind cluster + Redis + Tyk OSS Gateway + the mock MCP
# server, fully automated (see lab-guide.md §2 for the manual walkthrough this
# replaces, and for what each step means). Run this once before demo day.
#
# Every step here was exercised against a real kind cluster while building
# this repo. Real-world fixes baked in that the original manual guide didn't
# know about yet:
#   - Bitnami's Docker Hub images for the exact pinned redis tag were pulled
#     from docker.io/bitnami/* in mid-2025's Bitnami/Broadcom restructuring;
#     the free replacement is docker.io/bitnamilegacy/*.
#   - The tyk-oss chart's default gateway image tag is older than the MCP
#     Gateway feature needs; this pins v5.13.2 explicitly.
#   - ⚠ The big one, found only by reading the gateway's own Go source:
#     registering an MCP proxy via POST /tyk/apis/oas (the generic OAS
#     endpoint — what earlier versions of this script and guide used)
#     creates a perfectly working reverse-proxy API, but never sets
#     ApplicationProtocol="mcp" on it. IsMCP() on that API definition stays
#     false forever, which silently disables BOTH the tool-allowlist
#     enforcement and per-tool rate limiting — the request still proxies
#     fine (MCP traffic flows either way), so nothing errors; the governance
#     features just never engage. The actual dedicated endpoint is
#     POST /tyk/mcps (list: GET /tyk/mcps, update: PUT /tyk/mcps/{id}) —
#     that's what marks the API as MCP and turns both features on. Confirmed
#     live: a tool outside the allowlist now gets a real 403, and a per-key
#     rate limit (below) now genuinely 429s.
#
# Usage: ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=kcd-agent-demo
NAMESPACE=tyk-oss
APISecret=kcd-demo-secret
# Fixed, hardcoded to match x-tyk-api-gateway.info.id in tyk/mcp-proxy.json.
# This is what makes re-running this script safe: POSTing the same id twice
# updates the same API definition instead of Tyk silently accumulating a
# second "mock-mcp-governed" entry with a fresh random id every time (which
# is exactly what happened during testing — re-running without this ended up
# with duplicate entries, one of them stale, and no error to tell you so).
MOCK_API_ID=bd14dd7bcd764110b0e8bfac22c11a0c

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "==> Creating kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER"
else
  echo "==> kind cluster $CLUSTER already exists, reusing"
fi

if [ ! -d /tmp/tyk-mock-mcp-server ]; then
  echo "==> Cloning + building tyk-mock-mcp-server"
  git clone --depth 1 https://github.com/TykTechnologies/tyk-mock-mcp-server.git /tmp/tyk-mock-mcp-server
fi
docker build -t tyk-mock-mcp-server:local /tmp/tyk-mock-mcp-server
kind load docker-image tyk-mock-mcp-server:local --name "$CLUSTER"

helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Redis (Bitnami chart, bitnamilegacy images — see header comment)"
helm upgrade tyk-redis oci://registry-1.docker.io/bitnamicharts/redis \
  -n "$NAMESPACE" --install --version 19.0.2 \
  --set auth.password=demoRedisPass \
  --set image.repository=bitnamilegacy/redis \
  --set volumePermissions.image.repository=bitnamilegacy/os-shell \
  --set sentinel.image.repository=bitnamilegacy/redis-sentinel \
  --set metrics.image.repository=bitnamilegacy/redis-exporter

echo "==> Tyk OSS Gateway (v5.13.2, coprocess/gRPC plugins enabled by chart default)"
# --reuse-values matters if you ever re-run this AFTER part2-token-exchange/setup.sh:
# without it, a plain `helm upgrade` resets every value not re-specified here
# back to chart defaults — including the coprocess gRPC server address Part 2
# added — which respins the gateway pod and quietly breaks the token-exchange
# plugin wiring. Safe to run first-time too (there's nothing to preserve yet).
helm upgrade tyk-oss tyk-helm/tyk-oss -n "$NAMESPACE" --create-namespace --install \
  --reuse-values \
  --set global.secrets.APISecret="$APISecret" \
  --set global.redis.addrs="{tyk-redis-master.$NAMESPACE.svc.cluster.local:6379}" \
  --set global.redis.passSecret.name=tyk-redis \
  --set global.redis.passSecret.keyName=redis-password \
  --set tyk-gateway.gateway.image.repository=docker.tyk.io/tyk-gateway/tyk-gateway \
  --set tyk-gateway.gateway.image.tag=v5.13.2

echo "==> Waiting for gateway + redis pods"
kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=gateway-tyk-oss-tyk-gateway --timeout=180s
kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app.kubernetes.io/name=redis --timeout=180s || true

kubectl apply -f manifests/mcp-server.yaml

echo "==> Port-forward the gateway locally, then register the mock MCP proxy"
pkill -f "port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080" 2>/dev/null || true
(kubectl -n "$NAMESPACE" port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080 >/tmp/pf-gateway.log 2>&1 &)
sleep 3
curl -sf http://localhost:8080/tyk/mcps \
  -H "x-tyk-authorization: $APISecret" -H "Content-Type: application/json" \
  -d @tyk/mcp-proxy.json | python3 -m json.tool
curl -s http://localhost:8080/tyk/reload/group -H "x-tyk-authorization: $APISecret"
echo

# ⚠ Real, reproducible finding: /tyk/reload/group queues the reload and can
# return "ok" before the gateway has actually re-scanned its apps directory —
# on at least one clean run, the very next listing came back empty for
# several seconds with no error anywhere. Poll until the API we just
# registered is actually visible before doing anything that depends on it.
# Note this checks /tyk/mcps, not /tyk/apis — MCP-registered APIs live in a
# separate list from regular OAS ones; /tyk/apis will never show this one.
echo "==> Waiting for the gateway to pick up the registration"
for i in $(seq 1 20); do
  FOUND=$(curl -s http://localhost:8080/tyk/mcps -H "x-tyk-authorization: $APISecret" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
ids = {a.get('x-tyk-api-gateway',{}).get('info',{}).get('id') for a in d}
print('yes' if '$MOCK_API_ID' in ids else '')
")
  [ "$FOUND" = "yes" ] && break
  sleep 1
done
if [ "$FOUND" != "yes" ]; then
  echo "mock-mcp-governed never showed up in /tyk/mcps after registering — aborting."
  exit 1
fi

echo "==> Creating the demo key (unguarded — no rate limit yet; see CHEATSHEET.md to add/remove one live)"
# Fixed, custom key ID — same trick as MOCK_API_ID above. POST /tyk/keys/create
# mints a fresh random key on every call, which is exactly what bit us during
# testing: export TYK_MCP_KEY once, re-run setup.sh later, and your shell is
# silently holding a dead value. POSTing to /tyk/keys/{custom-id} instead makes
# the resulting key DETERMINISTIC (it's just base64 of {"org":"","id":"<custom-id>",
# "h":"murmur128"}) — confirmed live: re-running this script always reproduces
# byte-for-byte the same key. Re-running is now genuinely idempotent and safe
# to `export` once and forget.
WORKSHOP_KEY_ID=workshop-demo-key-001
# Deliberately no mcp_primitives here — this key starts UNGOVERNED (rate-limit
# wise) so the first cheat-sheet demo beat is a real "no limits" happy path.
# The tool allowlist (mcpTools.*.allow, set on the API definition itself) still
# applies to every key on this API regardless — confirmed live: calling a tool
# outside that allowlist gets a real 403 even on this "unguarded" key.
FULL_KEY=$(curl -s -X POST "http://localhost:8080/tyk/keys/$WORKSHOP_KEY_ID" -H "x-tyk-authorization: $APISecret" -H "Content-Type: application/json" -d "{
  \"alias\": \"workshop-full-key\",
  \"org_id\": \"\",
  \"access_rights\": {
    \"$MOCK_API_ID\": {
      \"api_id\": \"$MOCK_API_ID\", \"api_name\": \"mock-mcp-governed\", \"versions\": [\"Default\"]
    }
  }
}" | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
# True per-key "filtered discovery" (a second key that sees FEWER tools in
# tools/list) needs a second, more-restrictive MCP proxy API definition —
# Tyk OSS's mcpTools.allow is API-definition-scoped, not per-key. See
# lab-guide.md §6.3 for how to set that up as a live demo step.

echo "$FULL_KEY" > /tmp/tyk_mcp_key.txt
echo "==> Done. Gateway reachable at http://localhost:8080 (keep the port-forward above running)."
echo "==> Demo key (fixed, unguarded) written to /tmp/tyk_mcp_key.txt. Run:"
echo "    export TYK_MCP_URL=\"http://localhost:8080/mcp-gw/mcp\""
echo "    export TYK_MCP_KEY=\"\$(cat /tmp/tyk_mcp_key.txt)\""
echo "    python agent.py \"How many users are in the system?\""
echo "==> Now follow CHEATSHEET.md for the live governance demo sequence (rate limit on/off, AI Studio RBAC, token exchange)."

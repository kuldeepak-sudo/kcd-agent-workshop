#!/bin/bash
# Part 2 — MCP Token Exchange (Acme Support Copilot), on Tyk OSS only.
#
# Every step in this script was run against a live kind cluster while building
# this deployment; see the comments for the real bugs/gotchas that were found
# and fixed. Run this AFTER Part 1's pre-flight (kind cluster + Redis + Tyk OSS
# Gateway must already exist — see ../lab-guide.md sections 2.2 and 4.1, or
# just run ../setup.sh first) since this reuses that same cluster, namespace,
# and gateway.
#
# Usage: ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=kcd-agent-demo
NAMESPACE=tyk-oss
APISecret=kcd-demo-secret
GATEWAY_LOCAL=http://localhost:8080

# Fixed, hardcoded to match x-tyk-api-gateway.info.id in the two tyk/*.json
# files below. This is what makes the whole script idempotent — no step
# depends on resolving an api_id at runtime, which was the source of every
# race condition found while building this (an unreloaded /tyk/apis listing
# returning empty, a policy silently written with an empty access_rights key,
# duplicate API registrations piling up on every re-run).
ACME_MCP_ID=87ba7c68b57f45ed85269b5a3ad897d4
ACME_API_ID=7cec799338bb41b58627cb21ab047640

echo "==> Building images"
docker build -t acme-token-exchange-plugin:local services/token-exchange-plugin
docker build -t acme-resource-api:local services/acme-resource-api
docker build -t acme-mcp-server:local services/acme-mcp-server
docker build -t acme-chat:local services/acme-chat

echo "==> Loading images into kind"
for img in acme-token-exchange-plugin:local acme-resource-api:local acme-mcp-server:local acme-chat:local; do
  kind load docker-image "$img" --name "$CLUSTER"
done

echo "==> Enabling coprocess (gRPC plugin) on the Tyk OSS Gateway"
# ⚠ The chart's default env already sets TYK_GW_COPROCESSOPTIONS_ENABLECOPROCESS=true
# unconditionally (verified by rendering the chart with `helm template`) — do NOT
# also set it via extraEnvs, Helm will reject the render with a "duplicate
# entries" error. Only the gRPC server address needs adding.
helm upgrade tyk-oss tyk-helm/tyk-oss -n "$NAMESPACE" --reuse-values \
  --set-json 'tyk-gateway.gateway.extraEnvs=[{"name":"TYK_GW_COPROCESSOPTIONS_COPROCESSGRPCSERVER","value":"tcp://acme-token-exchange-plugin.tyk-oss.svc.cluster.local:5555"}]'

echo "==> ConfigMaps (realm import, OAS spec for acme-mcp-server, Tyk policy)"
kubectl create configmap acme-keycloak-realm -n "$NAMESPACE" \
  --from-file=realm-acme.json=realm/realm-acme.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap acme-api-oas -n "$NAMESPACE" \
  --from-file=acme-api.oas.json=tyk/acme-api.oas.json \
  --dry-run=client -o yaml | kubectl apply -f -

# ⚠ IMPORTANT, hard-won finding: the tyk-oss Helm chart sets BOTH
# Policies.PolicyPath (a directory) and Policies.PolicyRecordName (a file
# inside it). Tyk's server.go prefers PolicyPath when it's set, which routes
# through LoadPoliciesFromDir — that function decodes each *.json file in the
# directory as ONE SINGLE user.Policy object, NOT a map of named policies (the
# shape the classic /policies.json convention and most docs/examples show).
# Get this wrong and you get no error, just "Policies found (1 total)" at boot
# and "policy not found" on every request — the file parses, but every field
# lands on an empty Policy struct. The fix: one policy object per file, with
# "id" as a plain top-level field.
cat > /tmp/acme-policies.json <<EOF
{
  "id": "acme-demo-default",
  "name": "acme-demo-default",
  "org_id": "",
  "active": true,
  "rate": 1000,
  "per": 1,
  "quota_max": -1,
  "quota_renewal_rate": 60,
  "access_rights": {
    "$ACME_API_ID": {"api_id": "$ACME_API_ID", "api_name": "acme-api", "versions": ["Default"], "allowed_urls": []},
    "$ACME_MCP_ID": {"api_id": "$ACME_MCP_ID", "api_name": "acme-mcp-proxy", "versions": ["Default"], "allowed_urls": []}
  }
}
EOF
kubectl create configmap tyk-oss-policies -n "$NAMESPACE" \
  --from-file=policies.json=/tmp/acme-policies.json \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying Keycloak, the plugin, the resource API, the MCP server, and the chat UI"
kubectl apply -f manifests/keycloak.yaml
kubectl apply -f manifests/token-exchange-plugin.yaml
kubectl apply -f manifests/acme-resource-api.yaml
kubectl apply -f manifests/acme-mcp-server.yaml
kubectl apply -f manifests/acme-chat.yaml

echo "==> Mounting the policy file into the gateway (first run only) and restarting"
# ⚠ The gateway image has no shell/tar (kubectl exec/cp won't work on it), and
# a subPath ConfigMap mount does NOT live-update — so the FIRST time this runs,
# patch the volume in; every subsequent run just needs the restart below,
# which re-mounts the (by-then-already-updated) ConfigMap fresh. The restart
# also wipes the gateway's emptyDir app store, which is why we always
# register the OAS APIs (below) AFTER this, never before.
if ! kubectl -n "$NAMESPACE" get deployment gateway-tyk-oss-tyk-gateway -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tyk-oss-policies")]}' | grep -q tyk-oss-policies; then
  kubectl -n "$NAMESPACE" patch deployment gateway-tyk-oss-tyk-gateway --type=json -p '[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"tyk-oss-policies","configMap":{"name":"tyk-oss-policies"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"tyk-oss-policies","mountPath":"/mnt/tyk-gateway/policies/policies.json","subPath":"policies.json"}}
  ]'
fi
kubectl -n "$NAMESPACE" rollout restart deployment/gateway-tyk-oss-tyk-gateway
kubectl -n "$NAMESPACE" rollout status deployment/gateway-tyk-oss-tyk-gateway --timeout=120s

echo "==> Waiting for Keycloak to import the realm (can take ~30-60s)"
ready=false
for i in $(seq 1 30); do
  ready=$(kubectl -n "$NAMESPACE" get pod -l app=acme-keycloak -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  [ "$ready" = "true" ] && break
  sleep 5
done
[ "$ready" = "true" ] || { echo "Keycloak did not become ready in time"; exit 1; }

echo "==> Registering the two Tyk OAS APIs (plus re-registering Part 1's, if present)"
# The gateway's app store is an emptyDir, so the restart above just wiped
# whatever Part 1's ../setup.sh had registered too — re-register it here so
# Part 1's demo doesn't silently stop working the moment Part 2 is stood up.
pkill -f "port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080" 2>/dev/null || true
(kubectl -n "$NAMESPACE" port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080 >/tmp/part2-pf-gateway.log 2>&1 &)
for i in $(seq 1 20); do
  curl -sf -o /dev/null "$GATEWAY_LOCAL/hello" && break
  sleep 1
done
if [ -f ../tyk/mcp-proxy.json ]; then
  echo "  - ../tyk/mcp-proxy.json (Part 1)"
  curl -sf "$GATEWAY_LOCAL/tyk/apis/oas" \
    -H "x-tyk-authorization: $APISecret" -H "Content-Type: application/json" \
    -d @../tyk/mcp-proxy.json | python3 -m json.tool
fi
for f in tyk/acme-mcp-proxy.oas.json tyk/acme-api.oas.json; do
  echo "  - $f"
  curl -sf "$GATEWAY_LOCAL/tyk/apis/oas" \
    -H "x-tyk-authorization: $APISecret" -H "Content-Type: application/json" \
    -d @"$f" | python3 -m json.tool
done
curl -s "$GATEWAY_LOCAL/tyk/reload/group" -H "x-tyk-authorization: $APISecret"
echo

echo "==> Waiting for the gateway to pick up both registrations"
for i in $(seq 1 20); do
  BOTH=$(curl -s "$GATEWAY_LOCAL/tyk/apis" -H "x-tyk-authorization: $APISecret" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
ids = {a.get('api_id') for a in d}
print('yes' if {'$ACME_MCP_ID','$ACME_API_ID'} <= ids else '')
")
  [ "$BOTH" = "yes" ] && break
  sleep 1
done
if [ "$BOTH" != "yes" ]; then
  echo "acme-mcp-proxy / acme-api never both showed up in /tyk/apis — aborting."
  exit 1
fi

echo "==> Done. Add to /etc/hosts (needed once):  127.0.0.1 acme-keycloak"
echo "==> Then, in separate terminals:"
echo "    kubectl -n tyk-oss port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080"
echo "    kubectl -n tyk-oss port-forward svc/acme-keycloak 8280:8280"
echo "    kubectl -n tyk-oss port-forward svc/acme-chat 8095:8090"
echo "==> Open http://localhost:8095 and sign in as alice / Acme-Demo-2026!"

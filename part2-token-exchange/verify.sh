#!/bin/bash
# Headless end-to-end check of the token-exchange flow — no browser needed.
# Run this AFTER ./setup.sh, with these already running in other terminals:
#   kubectl -n tyk-oss port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080
#   kubectl -n tyk-oss port-forward svc/acme-keycloak 8280:8280
set -euo pipefail

GW=http://localhost:8080
KC=http://localhost:8280

get_token() {
  curl -sf -H "Host: acme-keycloak:8280" \
    -d "grant_type=password" -d "client_id=acme-support-chat" \
    -d "username=$1" -d "password=Acme-Demo-2026!" -d "scope=openid customers:all" \
    "$KC/realms/acme/protocol/openid-connect/token" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])"
}

mcp_session() {
  local token=$1
  curl -s -D - "$GW/acme-mcp/mcp" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}' \
    -o /dev/null | grep -i Mcp-Session-Id | tr -d '\r' | awk '{print $2}'
}

call_tool() {
  local token=$1 sid=$2 tool=$3 args=$4
  curl -s "$GW/acme-mcp/mcp" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" >/dev/null
  curl -s "$GW/acme-mcp/mcp" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}"
}

echo "==> alice: lookup_customer (expect success)"
ALICE=$(get_token alice)
SID=$(mcp_session "$ALICE")
OUT=$(call_tool "$ALICE" "$SID" lookup_customer '{"customer_id":"C-1024"}')
echo "$OUT" | grep -q '"status":200' && echo "  PASS" || { echo "  FAIL: $OUT"; exit 1; }

echo "==> alice: issue_refund (expect denied, insufficient_scope)"
SID=$(mcp_session "$ALICE")
OUT=$(call_tool "$ALICE" "$SID" issue_refund '{"customer_id":"C-1024","amount":25}')
echo "$OUT" | grep -q "insufficient_scope" && echo "  PASS" || { echo "  FAIL: $OUT"; exit 1; }

echo "==> bob: issue_refund (expect success)"
BOB=$(get_token bob)
SID=$(mcp_session "$BOB")
OUT=$(call_tool "$BOB" "$SID" issue_refund '{"customer_id":"C-1024","amount":25}')
echo "$OUT" | grep -q '"status":200' && echo "  PASS" || { echo "  FAIL: $OUT"; exit 1; }

echo "==> All checks passed."

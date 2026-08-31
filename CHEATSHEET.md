# Cheat sheet — run this in order, live

Copy-paste sequence for the KCD talk. Full narrative and "why" for every step
is in [`lab-guide.md`](./lab-guide.md); this file is just the commands, in the
order you run them, Tell → Show → Do.

Every command below was run against a real kind cluster + AI Studio stack
while writing this — outputs shown are what you should actually see.

---

## 0. Install everything (do this before the room fills up)

```bash
git clone <this-repo-url> kcd-agent-workshop && cd kcd-agent-workshop

# Part 1 — kind cluster, Redis, Tyk OSS Gateway, mock MCP server
./setup.sh

# Part 2 (LLM governance) — Tyk AI Studio CE, its own Docker Compose stack
./ai-studio/setup.sh

# Part 3 (identity governance) — Keycloak, token-exchange plugin, ACME demo apps
cd part2-token-exchange && ./setup.sh && cd ..
```

All three are idempotent — safe to re-run any of them mid-workshop if something
needs restarting.

Keep these port-forwards running in background terminals for the rest of the
session:

```bash
kubectl -n tyk-oss port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080
kubectl -n tyk-oss port-forward svc/acme-keycloak 8280:8280
kubectl -n tyk-oss port-forward svc/acme-chat 8095:8095
```

Set the Part 1 demo env vars (the key is fixed — `setup.sh` always produces the
same value, so this only needs doing once per shell):

```bash
export TYK_MCP_URL="http://localhost:8080/mcp-gw/mcp"
export TYK_MCP_KEY="$(cat /tmp/tyk_mcp_key.txt)"
```

---

## 1. Part 1 — MCP tool governance (Tyk OSS Gateway)

### 1a. Happy path — unguarded

Fresh off `setup.sh`, the demo key has **no rate limit**. Open an MCP session
and hammer `get_anything` — everything succeeds:

```bash
SID=$(curl -s -D - "$TYK_MCP_URL" \
  -H "Authorization: Bearer $TYK_MCP_KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}}}' \
  -o /dev/null | grep -i Mcp-Session-Id | tr -d '\r' | awk '{print $2}')

curl -s "$TYK_MCP_URL" -H "Authorization: Bearer $TYK_MCP_KEY" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

for i in $(seq 1 8); do
  curl -s -o /dev/null -w "%{http_code} " "$TYK_MCP_URL" \
    -H "Authorization: Bearer $TYK_MCP_KEY" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_anything","arguments":{}}}'
done; echo
```

**Expect:** `200 200 200 200 200 200 200 200`

Also worth showing here: the tool *allowlist* is always on, even on this
"unguarded" key — try a tool that isn't in `tyk/mcp-proxy.json`'s `mcpTools`
block (e.g. `delete_user`) and it's a real `403`, not a 200. "Unguarded" in
this demo means no rate limit yet, not no governance at all.

### 1b. Apply rate limiting

Per-tool rate limits live on the **key**, not the API definition — this `PUT`
adds a 5-per-60s limit on `get_anything`:

```bash
ENC_KEY=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$TYK_MCP_KEY")

curl -s -X PUT "http://localhost:8080/tyk/keys/$ENC_KEY" \
  -H "x-tyk-authorization: kcd-demo-secret" -H "Content-Type: application/json" -d '{
  "alias": "workshop-full-key",
  "org_id": "",
  "access_rights": {
    "bd14dd7bcd764110b0e8bfac22c11a0c": {
      "api_id": "bd14dd7bcd764110b0e8bfac22c11a0c", "api_name": "mock-mcp-governed", "versions": ["Default"],
      "mcp_primitives": [ {"type": "tool", "name": "get_anything", "limit": {"rate": 5, "per": 60}} ]
    }
  }
}'
```

Re-run the exact same 8-call loop from 1a (same `$SID` is fine).

**Expect:** `200 200 200 200 200 429 429 429`

### 1c. Remove rate limiting

Same `PUT`, minus the `mcp_primitives` array:

```bash
curl -s -X PUT "http://localhost:8080/tyk/keys/$ENC_KEY" \
  -H "x-tyk-authorization: kcd-demo-secret" -H "Content-Type: application/json" -d '{
  "alias": "workshop-full-key",
  "org_id": "",
  "access_rights": {
    "bd14dd7bcd764110b0e8bfac22c11a0c": {
      "api_id": "bd14dd7bcd764110b0e8bfac22c11a0c", "api_name": "mock-mcp-governed", "versions": ["Default"]
    }
  }
}'
```

Wait out the current 60s window, then re-run the loop.

**Expect:** back to `200 200 200 200 200 200 200 200`

---

## 2. Part 2 — LLM governance (Tyk AI Studio CE)

AI Studio's control plane (port 3000) is what's confirmed working end to end;
the actual chat-completions call through its microgateway (port 9091) has a
known unresolved bug (see `ai-studio/README.md`) — so this beat is shown at
the config/API level, which is real and live, rather than as a completions
call.

Log in once per shell session (cookies expire):

```bash
AI_BASE=http://localhost:3000
AI_COOKIES=/tmp/ai-studio-cookies.txt
csrf() { curl -s -b "$AI_COOKIES" -c "$AI_COOKIES" -D - "$AI_BASE/csrf-token" -o /dev/null | grep -i X-Csrf-Token | tr -d '\r' | awk '{print $2}'; }

rm -f "$AI_COOKIES"
curl -s -X POST "$AI_BASE/auth/login" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$AI_COOKIES" -c "$AI_COOKIES" -d '{
  "data":{"type":"users","attributes":{"email":"admin@kcd-workshop.local","password":"Workshop-Demo-2026!"}}}'
```

Look up the app + LLM ids (names are stable, ids can vary by install):

```bash
APP_ID=$(curl -s -b "$AI_COOKIES" "$AI_BASE/api/v1/apps/by-name?name=workshop-agent" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
ALL_LLM_IDS=$(curl -s -b "$AI_COOKIES" "$AI_BASE/api/v1/llms" | python3 -c "import json,sys; print(json.dumps([int(l['id']) for l in json.load(sys.stdin)['data']]))")
WORKSHOP_LLM_ID=$(curl -s -b "$AI_COOKIES" "$AI_BASE/api/v1/llms" | python3 -c "
import json,sys
for l in json.load(sys.stdin)['data']:
    if l['attributes']['name'] == 'workshop-llm': print(l['id'])")
echo "app=$APP_ID  all llms=$ALL_LLM_IDS  workshop-llm=$WORKSHOP_LLM_ID"
```

### 2a. Unguarded — the app can call any configured LLM

```bash
curl -s -X PATCH "$AI_BASE/api/v1/apps/$APP_ID" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$AI_COOKIES" -c "$AI_COOKIES" -d "{
  \"data\":{\"type\":\"apps\",\"attributes\":{\"name\":\"workshop-agent\",\"description\":\"KCD workshop demo app\",\"llm_ids\":$ALL_LLM_IDS}}
}"

curl -s -b "$AI_COOKIES" "$AI_BASE/api/v1/apps/$APP_ID" | python3 -m json.tool
```

**Expect:** `llm_ids` lists every LLM entry (OpenAI, Anthropic, workshop-llm)
— this app's credential can be pointed at any model in the org, no
restriction. Show this in the UI too: `http://localhost:3000` →
Apps → workshop-agent.

### 2b. Simple RBAC — narrow the app to one model

```bash
curl -s -X PATCH "$AI_BASE/api/v1/apps/$APP_ID" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$AI_COOKIES" -c "$AI_COOKIES" -d "{
  \"data\":{\"type\":\"apps\",\"attributes\":{\"name\":\"workshop-agent\",\"description\":\"KCD workshop demo app\",\"llm_ids\":[$WORKSHOP_LLM_ID]}}
}"

curl -s -b "$AI_COOKIES" "$AI_BASE/api/v1/apps/$APP_ID" | python3 -m json.tool
```

**Expect:** `llm_ids` now lists only `workshop-llm` — the same credential is
now scoped to exactly one model. Refresh the UI to show the same narrowing
there.

---

## 3. Part 3 — identity governance (MCP token exchange, Tyk OSS)

```bash
cd part2-token-exchange
./verify.sh
```

**Expect:**
```
==> alice: lookup_customer (expect success)
  PASS
==> alice: issue_refund (expect denied, insufficient_scope)
  PASS
==> bob: issue_refund (expect success)
  PASS
==> All checks passed.
```

For the live/visual version instead of the headless script, open the chat UI
(`http://localhost:8095`, port-forwarded in step 0), sign in as `alice` then
as `bob` (password `Acme-Demo-2026!` for both — see
`part2-token-exchange/README.md`), and use the Delegation inspector panel to
show the token narrowing in real time as each one tries `issue_refund`.

---

## Reset between runs / rehearsals

```bash
# Part 1: strip the rate limit back off (see 1c) if you skip straight to a re-run
# Part 2: reset the app back to "unguarded" (see 2a) before your next run-through
# Part 3: nothing to reset — verify.sh is stateless per run
```

#!/bin/bash
# LLM governance — Tyk AI Studio Community Edition, via its official Docker
# Compose quickstart (no Kubernetes chart is verified working as of this
# build; the docker-compose path below was verified live and is what this
# script automates end to end).
#
# Real bugs found and fixed while building this, baked in below:
#   - The upstream repo's quickstart/confs/mgw-ce.env ships CONTROL_ENDPOINT=
#     midsommar:9080, but the control-plane container's own GRPC_PORT is
#     50051 — the microgateway container crash-loops forever with "connection
#     refused" until this is corrected.
#   - The root README's claim of port 8585 for the CE quickstart UI is wrong;
#     the compose file that actually ships (quickstart/ce/compose.yaml) maps
#     the UI to port 3000. 8585 is the Enterprise edition's port.
#   - There is no ADMIN_EMAIL env var (an earlier version of this guide
#     assumed one) — the first account to POST /auth/register becomes admin,
#     full stop.
#   - The admin API requires a CSRF token fetched from GET /csrf-token first
#     (X-CSRF-Token header) — skip it and every POST 403s with a body that
#     looks like a stray log line concatenated onto a real JSON response.
#   - PATCH /api/v1/llms/:id is a full replace, not a partial merge — PATCHing
#     just {"api_key": "..."} silently blanks the record's name/vendor/active
#     fields. This script always reads the current record and PATCHes the
#     complete object back.
#
# ⚠ NOT resolved by this script — read the final printed output, not just
# this list: the actual chat-completions call through the microgateway
# (:9091) is still unconfirmed. The pinned image (tykio/tyk-microgateway
# v2.0.0) predates the ai-studio repo's current `main` branch — its mounted
# routes are "/llm/* /tools/* /datasource/*" only, not the "/v1/*" unified
# endpoint the current source documents. The older equivalent endpoint
# (POST /llm/call/{slug}/v1/chat/completions) does exist, but the edge
# process behind :9091 never actually loads the LLM/app/credential this
# script creates — its logs repeat "Edge is out of sync with control -
# configuration update pending" every ~30s forever, with the loaded
# checksum never changing across 5+ minutes of retries or a full container
# restart. Confirmed by watching the error change over time: a fresh edge
# rejects the credential outright ("Invalid or expired bearer token", 401);
# after longer uptime the same credential gets past auth but then hits
# "LLM not found" (404) — consistent with the edge being stuck at its very
# first config snapshot from container start. This needs a live rehearsal
# before demo day — see the script's own final output for the exact curl
# to try.
#
# Usage:
#   ./setup.sh                                   # sets everything up, LLM key left blank
#   ANTHROPIC_API_KEY=sk-... ./setup.sh          # also wires up a real Anthropic key
#   AI_STUDIO_LLM_VENDOR=openai OPENAI_API_KEY=sk-... ./setup.sh   # same, for OpenAI
#
# Safe to re-run any time — every step below is idempotent.
set -euo pipefail
cd "$(dirname "$0")"

REPO_DIR=/tmp/tyk-ai-studio
BASE=http://localhost:3000
MGW_BASE=http://localhost:9091
ADMIN_EMAIL=admin@kcd-workshop.local
ADMIN_PASSWORD='Workshop-Demo-2026!'
LLM_NAME=workshop-llm
APP_NAME=workshop-agent
COOKIES=/tmp/ai-studio-cookies.txt

VENDOR="${AI_STUDIO_LLM_VENDOR:-anthropic}"
if [ "$VENDOR" = "openai" ]; then
  DEFAULT_MODEL="gpt-4o-mini"
  API_KEY="${OPENAI_API_KEY:-}"
else
  VENDOR=anthropic
  DEFAULT_MODEL="claude-3-5-haiku-20241022"
  API_KEY="${ANTHROPIC_API_KEY:-}"
fi
MODEL="${AI_STUDIO_LLM_MODEL:-$DEFAULT_MODEL}"

echo "==> Cloning Tyk AI Studio (CE quickstart)"
if [ ! -d "$REPO_DIR" ]; then
  git clone --depth 1 https://github.com/TykTechnologies/ai-studio.git "$REPO_DIR"
fi

echo "==> Fixing the CONTROL_ENDPOINT port mismatch (see header comment)"
sed -i.bak 's/CONTROL_ENDPOINT=midsommar:9080/CONTROL_ENDPOINT=midsommar:50051/' \
  "$REPO_DIR/quickstart/confs/mgw-ce.env"

echo "==> Starting the CE stack (UI :3000, microgateway :9091)"
(cd "$REPO_DIR/quickstart" && docker compose -f ce/compose.yaml up -d)

echo "==> Waiting for the UI and microgateway to come up"
for i in $(seq 1 30); do
  curl -sf -o /dev/null "$BASE" && curl -sf -o /dev/null "$MGW_BASE" && break
  sleep 2
done
curl -sf -o /dev/null "$BASE" || { echo "AI Studio UI never came up on :3000"; exit 1; }
curl -sf -o /dev/null "$MGW_BASE" || {
  echo "Microgateway never came up on :9091 — check: docker logs \$(docker ps -qf name=ce-mgw)"
  exit 1
}

csrf() {
  curl -s -b "$COOKIES" -c "$COOKIES" -D - "$BASE/csrf-token" -o /dev/null \
    | grep -i X-Csrf-Token | tr -d '\r' | awk '{print $2}'
}

echo "==> Registering the admin account (or confirming it already exists)"
rm -f "$COOKIES"
REG=$(curl -s -X POST "$BASE/auth/register" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$COOKIES" -c "$COOKIES" -d "{
  \"data\":{\"type\":\"users\",\"attributes\":{
    \"email\":\"$ADMIN_EMAIL\",\"name\":\"Workshop Admin\",\"password\":\"$ADMIN_PASSWORD\",
    \"with_portal\":true,\"with_chat\":true
  }}
}")
if ! echo "$REG" | grep -q "registered successfully\|already in use"; then
  echo "Unexpected register response: $REG"
  exit 1
fi

echo "==> Logging in"
LOGIN=$(curl -s -X POST "$BASE/auth/login" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$COOKIES" -c "$COOKIES" -d "{
  \"data\":{\"type\":\"users\",\"attributes\":{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}}}
")
echo "$LOGIN" | grep -q "Login successful" || { echo "Login failed: $LOGIN"; exit 1; }

echo "==> Creating (or finding) the '$LLM_NAME' LLM entry"
LLM_ID=$(curl -s -b "$COOKIES" "$BASE/api/v1/llms" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for l in d.get('data', []):
    if l['attributes']['name'] == '$LLM_NAME':
        print(l['id']); break
")
if [ -z "$LLM_ID" ]; then
  RESP=$(curl -s -X POST "$BASE/api/v1/llms" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$COOKIES" -c "$COOKIES" -d "{
    \"data\":{\"type\":\"llms\",\"attributes\":{
      \"name\":\"$LLM_NAME\",\"vendor\":\"$VENDOR\",\"active\":true,
      \"api_key\":\"$API_KEY\",\"default_model\":\"$MODEL\",\"allowed_models\":[\"$MODEL\"],
      \"short_description\":\"KCD workshop demo model\"
    }}
  }")
  LLM_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
  echo "  created id=$LLM_ID"
elif [ -n "$API_KEY" ]; then
  # PATCH is a full replace here (see header comment) — read the current
  # record and send the whole thing back with the key filled in, rather than
  # risk silently blanking name/vendor/active with a partial payload.
  CUR=$(curl -s -b "$COOKIES" "$BASE/api/v1/llms/$LLM_ID" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['data']['attributes']))")
  curl -s -X PATCH "$BASE/api/v1/llms/$LLM_ID" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$COOKIES" -c "$COOKIES" -d "{
    \"data\":{\"type\":\"llms\",\"attributes\": $(python3 -c "
import json
attrs = json.loads('''$CUR''')
attrs['api_key'] = '''$API_KEY'''
print(json.dumps(attrs))
")}
  }" >/dev/null
  echo "  updated id=$LLM_ID with a key from \$${VENDOR^^}_API_KEY"
else
  echo "  found id=$LLM_ID (no key on hand to add — see below)"
fi

echo "==> Creating (or finding) the '$APP_NAME' app, granted access to $LLM_NAME"
APP=$(curl -s -b "$COOKIES" "$BASE/api/v1/apps/by-name?name=$APP_NAME")
if echo "$APP" | grep -q "Not Found"; then
  APP=$(curl -s -X POST "$BASE/api/v1/apps" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$COOKIES" -c "$COOKIES" -d "{
    \"data\":{\"type\":\"apps\",\"attributes\":{
      \"name\":\"$APP_NAME\",\"description\":\"KCD workshop demo app\",\"llm_ids\":[$LLM_ID]
    }}
  }")
fi
APP_ID=$(echo "$APP" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
CRED_ID=$(echo "$APP" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['attributes']['credential_id'])")

echo "==> Activating the app's credential"
curl -s -X POST "$BASE/api/v1/apps/$APP_ID/activate-credential" -H "Content-Type: application/json" -H "X-CSRF-Token: $(csrf)" -b "$COOKIES" -c "$COOKIES" -d '{}' >/dev/null
CRED=$(curl -s -b "$COOKIES" "$BASE/api/v1/credentials/$CRED_ID")
SECRET=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['attributes']['secret'])")
echo "$SECRET" > /tmp/ai_studio_key.txt

echo
echo "==> Done — admin, LLM entry, app, and credential are all live and confirmed"
echo "    against the control plane's own API (port 3000)."
echo "    UI:  http://localhost:3000  ($ADMIN_EMAIL / $ADMIN_PASSWORD)"
echo
if [ -z "$API_KEY" ]; then
  echo "    No $([ "$VENDOR" = openai ] && echo OPENAI_API_KEY || echo ANTHROPIC_API_KEY) was set, so '$LLM_NAME' has no key yet."
  echo "    Add one via the UI (sign in, LLMs -> $LLM_NAME -> add key), or re-run:"
  echo "      $([ "$VENDOR" = openai ] && echo OPENAI_API_KEY=sk-... || echo ANTHROPIC_API_KEY=sk-ant-...) ./setup.sh"
  echo
fi
cat <<'EOF'
==> ⚠ NOT yet confirmed: the actual chat-completions call through the
    microgateway (:9091). This needed more digging than expected — the
    picture that emerged from testing:

    - The shipped image (tykio/tyk-ai-studio / tyk-microgateway v2.0.0,
      built 2026-03-11) is OLDER than the ai-studio repo's current `main`
      branch. Its own debug log lists the gateway's mounted endpoints as
      exactly "/llm/* /tools/* /datasource/*" — no /v1/*, no /ai/*. The
      "/v1/chat/completions" unified-router endpoint documented in current
      `main`-branch source does not exist in this image; it plain-404s.
    - The actual (older) OpenAI-format endpoint for this image is
      POST /llm/call/{llm-slug}/v1/chat/completions — that route DOES
      match (confirmed: it returns a real JSON error, not a 404).
    - What's unresolved: the edge never actually loads the LLM you just
      created. The microgateway is a separate "edge" process with its own
      locally-synced SQLite copy of the control plane's config (a
      hub-and-spoke design). Its logs repeat "Edge is out of sync with
      control - configuration update pending" every ~30s, FOREVER — the
      loaded_checksum never changes across 5+ minutes of retries, even
      right after a full container restart. First symptom seen: the
      credential secret got "Invalid or expired bearer token" (401).
      After the edge had been running longer, the SAME secret got past
      auth but then "LLM not found" (404) — consistent with the edge's
      local copy of the config being permanently stuck at its very first
      snapshot from container start, never applying the update that adds
      your LLM/app/credential at all.

    Before relying on this live: rehearse the actual call once, e.g.:
      curl http://localhost:9091/llm/call/workshop-llm/v1/chat/completions \
        -H "Authorization: Bearer $(cat /tmp/ai_studio_key.txt)" \
        -H "Content-Type: application/json" \
        -d '{"model":"claude-3-5-haiku-20241022","messages":[{"role":"user","content":"hi"}]}'
    If that still 401s, check `docker logs $(docker ps -qf name=ce-mgw)`
    for "out of sync" warnings, and try `docker compose -f
    /tmp/tyk-ai-studio/quickstart/ce/compose.yaml restart mgw` once more
    a minute or two after this script finishes (the edge may just need
    longer to converge than this script waits for).
EOF

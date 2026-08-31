# LLM governance — Tyk AI Studio (Community Edition)

Fronts the agent's LLM calls with auth, RBAC, and cost/usage tracking — the model-call half of the governance story (§4–6 of `../lab-guide.md` covers the tool-call half via the Tyk MCP Gateway).

Runs on the host via Docker Compose, not in the kind cluster — AI Studio CE has no confirmed-working Kubernetes chart as of this build (see below).

## Run it

```bash
./setup.sh
# or, to also wire up a real key:
ANTHROPIC_API_KEY=sk-ant-... ./setup.sh
OPENAI_API_KEY=sk-...  AI_STUDIO_LLM_VENDOR=openai ./setup.sh
```

Safe to re-run any time. It clones the official CE quickstart, fixes a config bug in the project's own shipped files (see the script's header comment), brings up the UI (`:3000`) and microgateway (`:9091`), registers an admin account, and creates a demo LLM entry + app + activated API credential — all confirmed against the admin API.

## What's confirmed vs. not

**Confirmed working**, verified live against a real deployment:
- The CE Docker Compose stack comes up cleanly once the `CONTROL_ENDPOINT` port bug is patched (the microgateway container otherwise crash-loops forever on "connection refused").
- Admin registration, login, LLM-entry creation, app creation, and credential activation all work via the documented (if under-documented) admin REST API on port 3000.
- The UI is genuinely on port 3000 for CE, not 8585 (that's Enterprise) — the project's own two quickstart docs disagree with each other on this.
- **`llm_ids` on an app is real, live-testable RBAC**: `PATCH /api/v1/apps/{id}` with a broader or narrower `llm_ids` array genuinely changes which configured LLMs that app can call, confirmed by reading the app back after each PATCH. This is independent of the completions-call bug below — it's enforced and inspectable entirely within the control-plane API/UI. See `../CHEATSHEET.md` §2 for the exact "unguarded then simple RBAC" demo commands.

**Not confirmed** — the actual chat-completions call through the microgateway (`:9091`):
- The pinned image (`tykio/tyk-microgateway:v2.0.0`, built 2026-03-11) predates the `ai-studio` repo's current `main` branch. Its own debug logs list its mounted routes as `/llm/* /tools/* /datasource/*` — there is no `/v1/*` unified-router endpoint in this image, even though that's what current source documents.
- The older, actually-present equivalent (`POST /llm/call/{llm-slug}/v1/chat/completions`) does match — it returns a real JSON error rather than a 404.
- But the microgateway ("edge") process behind `:9091` never actually loads the LLM/app/credential this script creates. AI Studio uses a hub-and-spoke design where the edge keeps its own locally-synced SQLite copy of the control plane's config; its logs repeat `"Edge is out of sync with control - configuration update pending"` every ~30s, forever — the loaded checksum never changed across 5+ minutes of retries or a full container restart in testing. The symptom evolves with uptime: a fresh edge rejects the credential outright (`"Invalid or expired bearer token"`, 401); after longer uptime the same credential gets past auth but then hits `"LLM not found"` (404) — consistent with the edge being permanently stuck at its very first config snapshot from container start.

**If you need this working for a real demo**: rehearse it yourself well before you're on stage. `setup.sh`'s final output prints the exact curl command to test and what to check next. If you get it working, the fix is worth feeding back upstream to `TykTechnologies/ai-studio` — this looks like a genuine gap between what ships and what's documented, not a one-off misconfiguration.

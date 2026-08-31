# KCD workshop: Deploy an Agent, Then Govern It

Open source agent on Kubernetes — MCP server + Tyk OSS Gateway (MCP Gateway) + Tyk AI Studio (Community Edition) — with governance (auth, rate limits, tool allowlisting, filtered discovery, cost tracking, and identity delegation) made visible in a live demo. Everything runs on **Tyk OSS only** — no Tyk Dashboard, no Enterprise licence, anywhere in this repo.

## Follow along

1. **Clone this repo and install the prerequisites** (see below).
2. **[`CHEATSHEET.md`](./CHEATSHEET.md)** — the exact commands, in the order we run them live. Keep this open in a terminal during the talk.
3. **[`lab-guide.md`](./lab-guide.md)** — the full narrative behind every command: why each governance feature works the way it does, the bugs we hit building this and how they were found, and a troubleshooting table. Read this if a command doesn't do what the cheat sheet says, or if you want the deep-dive after the talk.

The workshop has three parts, all on the same kind cluster / Tyk OSS Gateway:

- **Part 1** — MCP tool governance (Tyk OSS MCP Gateway): auth, tool allowlisting, per-tool rate limiting.
- **Part 2** — LLM governance (Tyk AI Studio CE): a control plane for LLM access, apps, credentials, and simple RBAC over which models an app can call.
- **Part 3** ([`part2-token-exchange/`](./part2-token-exchange/)) — identity governance: an agent acting on behalf of a signed-in human, its access narrowed to one action via a custom Tyk OSS gRPC plugin implementing RFC 8693-style token exchange (no Enterprise licence needed).

## Prerequisites

- Docker Desktop (or another Docker daemon) running, with a few GB free for the kind cluster + AI Studio containers
- [`kind`](https://kind.sigs.k8s.io/), `kubectl`, `helm`
- Python 3.10+ (`python3 --version`) and `pip`
- `git`, `curl`

Nothing else needs installing up front — no LLM API key is required to run the whole workshop; Part 2's LLM governance beat is shown at the config/API level (see `CHEATSHEET.md` §2), not as a live completions call.

## Quickstart

```bash
git clone <this-repo-url> kcd-agent-workshop
cd kcd-agent-workshop
./setup.sh                                    # Part 1: kind cluster, Tyk OSS Gateway, mock MCP server
./ai-studio/setup.sh                          # Part 2: Tyk AI Studio CE
cd part2-token-exchange && ./setup.sh && cd .. # Part 3: Keycloak, token-exchange plugin, ACME demo
```

Then open [`CHEATSHEET.md`](./CHEATSHEET.md) and follow it top to bottom.

## Layout

```
CHEATSHEET.md          the exact commands to run, in order — start here for the live demo
lab-guide.md           the full workshop guide — narrative, timing, troubleshooting
setup.sh               Part 1 pre-flight, automated: cluster, Redis, Tyk OSS Gateway, mock MCP server
agent.py               the demo agent (LLM via Tyk AI Studio + tools via Tyk MCP Gateway)
requirements.txt       pip deps for agent.py
manifests/
  mcp-server.yaml      Deployment + Service for tyk-mock-mcp-server
tyk/
  mcp-proxy.json       Tyk OAS definition that registers the MCP server as a governed proxy
artifact.html          a standalone styled/printable version of lab-guide.md

ai-studio/             Tyk AI Studio CE (LLM governance) — see its own setup.sh header comment
  setup.sh             clones the CE quickstart, fixes a real shipped-config bug, registers
                       admin + an LLM entry + an app + an activated credential — one command
  README.md            what's confirmed working vs. still-unresolved in this build

part2-token-exchange/  Part 3 — token exchange on Tyk OSS (see its own README.md)
  setup.sh             builds images, deploys, registers APIs — one command
  verify.sh            headless end-to-end check of the full alice/bob token-exchange flow
  manifests/           Keycloak, the plugin, the resource API, the MCP server, the chat UI
  tyk/                 the two Tyk OAS definitions (MCP proxy + resource API)
  realm/               Keycloak realm import (users alice/bob, entitlements claim)
  services/
    token-exchange-plugin/  the custom Tyk OSS gRPC plugin that does the scope narrowing
    acme-resource-api/      the "downstream API" that independently verifies + enforces scope
    acme-mcp-server/        generic OpenAPI→MCP tool server (ported from tyk-demo, unchanged)
    acme-chat/               browser copilot UI with a Delegation inspector (ported, unchanged)
```

## Verified live (2026-08-31) — what actually works and what doesn't yet

This repo was built and exercised against a real kind cluster and a real AI Studio deployment, not just written from docs. Headline findings:

- **The MCP tool-allowlist and per-tool rate limit are genuinely enforced** — confirmed live (a disallowed tool gets a real 403; 5 allowed calls then 3×429). MCP proxies must be registered via `POST /tyk/mcps`, not the generic `/tyk/apis/oas` — only that endpoint sets `ApplicationProtocol="mcp"`, which is what the gateway's `IsMCP()` check gates both features on. Per-tool rate limits live on the **key** (`access_rights.<api_id>.mcp_primitives`), not the API definition. Both are baked into `setup.sh` and `tyk/mcp-proxy.json`; `CHEATSHEET.md` §1 shows applying and removing the limit live.
- **The demo key is a fixed, deterministic value**, not a randomly generated one — `setup.sh` creates it via a custom key ID (`POST /tyk/keys/{custom-id}`), so re-running `setup.sh` always reproduces the same key. This closes a real failure mode found while testing: a randomly generated key means `export`ing it once and re-running `setup.sh` later leaves your shell holding a dead value with no error to explain why governance "isn't working."
- **`agent.py` does a real MCP streamable-HTTP handshake** (`initialize` → `Mcp-Session-Id` → `notifications/initialized` → `tools/call`) and genuinely falls back to a no-LLM tool-call demo when AI Studio env vars aren't set — both found and fixed by actually running it end to end, not just reading it.
- **Part 2's LLM-access RBAC is real and live-testable** at the AI Studio control-plane API (port 3000): an app's `llm_ids` genuinely scopes which configured LLMs it can call, confirmed by PATCHing it live and reading it back. **One thing is still unresolved**: the actual chat-completions call through AI Studio's microgateway (`:9091`) — the shipped image predates the project's current docs, and the microgateway's "edge" process never actually loads the LLM/app/credential this repo creates. See `ai-studio/setup.sh`'s own printed output for the exact reproduction and what's been tried.
- **Part 3's full token-exchange flow works end-to-end**, verified with real Keycloak logins: alice (read-only) is denied a refund with `insufficient_scope`; bob (read+write) gets a refund issued; the token the resource API receives has bob's `sub` preserved, `aud` re-pointed, and `scope` narrowed to exactly `refunds:write`. Run `part2-token-exchange/verify.sh` for a headless check, or use the chat UI for the live/visual version.

## License / attribution

Built against Tyk's public docs and the `TykTechnologies/tyk-mock-mcp-server` and `TykTechnologies/ai-studio` open source repos, plus Tyk's own `tyk-demo` repo (`deployments/mcp-token-exchange`, reused for Part 3's Keycloak realm, chat UI, and MCP server) — full source list at the bottom of `lab-guide.md`.

# Part 2 — Token Exchange (Acme Support Copilot), on Tyk OSS only

A support copilot calls real company APIs **on behalf of** a signed-in support rep. The rep's login token is exchanged for an audience-scoped token that **keeps the rep's identity** (`sub`) while narrowing the `scope` to exactly the one action the tool needs — and the downstream API enforces that narrowed scope (read vs refund). This is the RFC 8693 **impersonation** flavor: no actor token, no `act` claim; the exchanged token's `azp` records the gateway's client as the caller.

This is a port of Tyk's own `tyk-demo` repo (`deployments/mcp-token-exchange`), which demonstrates the same scenario using Tyk's built-in Enterprise "OAuth 2.0 Token Exchange" middleware. **That middleware requires an Enterprise-scoped Tyk licence** — confirmed by that deployment's own `pre.sh`, which hard-fails without one. To keep this workshop's "everything open source" rule intact, this port reimplements the same behavior with a **custom Tyk OSS gRPC plugin** instead — gRPC/rich plugins are a long-standing Community Edition gateway capability, unrelated to and predating the newer Enterprise MCP+exchange feature bundle.

Run this after Part 1's pre-flight (`../setup.sh`) — it reuses that same kind cluster, `tyk-oss` namespace, and Tyk OSS Gateway.

## Architecture

```
alice/bob ──(Keycloak login)──> acme-chat
                                    │ bearer = alice's SSO token (scope: customers:all, entitlements: customers:read)
                                    ▼
                          Tyk OSS Gateway — acme-mcp-proxy (/acme-mcp/mcp)
                            • native JWT auth (JWKS from Keycloak) — OSS
                            • MCP tool routing — OSS
                            • custom gRPC plugin (postPlugins hook):
                                - reads the JSON-RPC tool name
                                - checks entitlements vs. the tool's required scope
                                - DENY (403) or MINT a new JWT: same sub, aud=api.acme.internal,
                                  azp=tyk-mcp-gateway, scope=<narrowed>
                                - rewrites the outbound Authorization header
                                    │ bearer = exchanged token
                                    ▼
                              acme-mcp-server (generic OpenAPI→MCP tool server)
                                    │ replays the (now-exchanged) bearer verbatim
                                    ▼
                          Tyk OSS Gateway — acme-api (custom domain api.acme.internal)
                            • native JWT auth (JWKS from the plugin, NOT Keycloak) — OSS
                                    ▼
                              acme-resource-api
                                • independently verifies the token's RS256 signature
                                • enforces the narrowed `scope` per operation
                                • echoes received headers back (httpbin-style) so the
                                  chat's Delegation inspector can show the exchanged
                                  token exactly as this API saw it
```

Everything above is a genuinely open source Tyk gateway capability: native JWT auth via JWKS, MCP tool routing, and gRPC coprocess plugins have all shipped in the Community Edition gateway independent of the newer Enterprise MCP-exchange bundle.

## What's real vs. what's a stand-in

- **Real**: Keycloak (unmodified realm import — same users, same `entitlements` protocol mapper, same client scopes as the original demo), the chat UI (unmodified), the generic OpenAPI→MCP server (unmodified), Tyk's own JWT auth and MCP routing.
- **Custom, built for this port**: `services/token-exchange-plugin` (the gRPC plugin that mints the narrowed token) and `services/acme-resource-api` (replaces httpbin — a minimal Go API with a small canned customer/order dataset, that independently verifies the exchanged token and enforces scope per operation, mimicking httpbin's `/anything` echo shape closely enough that the chat's existing "Delegation inspector" needed zero code changes).

## Run it

```bash
./setup.sh
```

Then, in separate terminals (add the `/etc/hosts` entry once):

```bash
sudo sh -c 'grep -q "acme-keycloak" /etc/hosts || echo "127.0.0.1 acme-keycloak" >> /etc/hosts'
kubectl -n tyk-oss port-forward svc/gateway-svc-tyk-oss-tyk-gateway 8080:8080
kubectl -n tyk-oss port-forward svc/acme-keycloak 8280:8280
kubectl -n tyk-oss port-forward svc/acme-chat 8095:8090
```

Open http://localhost:8095. Or skip the browser and run `./verify.sh` (with the gateway and Keycloak port-forwards above running) for a headless pass/fail check of the same three scenarios — this is the exact script used to confirm this deployment works before it was handed over.

### Demo users

Both sign in with password `Acme-Demo-2026!`:

- **alice** — `entitlements: customers:read`. Look-up/orders succeed; update/refund are blocked with `insufficient_scope`.
- **bob** — `entitlements: customers:read customers:write refunds:write`. Everything succeeds.

### The flow

1. Sign in as alice, run "look up a customer" — succeeds. Run "issue a refund" — blocked (403), inspector shows why.
2. Sign out, sign in as bob, issue the refund — succeeds. Inspector shows: same `sub` as alice's SSO token would have for the same user, `aud` re-pointed to `api.acme.internal`, `azp` = `tyk-mcp-gateway`, `scope` narrowed to exactly `refunds:write`.

## Testing without the browser

The whole chain can be driven headlessly (this is exactly how it was verified while building this):

```bash
# Get a real token via Keycloak's password grant (the chat client allows this)
curl -H "Host: acme-keycloak:8280" \
  -d "grant_type=password" -d "client_id=acme-support-chat" \
  -d "username=alice" -d "password=Acme-Demo-2026!" -d "scope=openid customers:all" \
  http://localhost:8280/realms/acme/protocol/openid-connect/token

# Then drive the MCP streamable-HTTP protocol directly: initialize -> capture
# Mcp-Session-Id -> notifications/initialized -> tools/call. See lab-guide.md
# §6.4 for the exact curl sequence (same handshake, different endpoint:
# /acme-mcp/mcp instead of /mcp-gw/mcp).
```

## Known gaps / next steps

- **The policy-file format landmine** (see `../lab-guide.md` §7.4) — already worked around in `setup.sh`, but worth understanding if you extend this with more policies.
- **Token TTL is fixed at 60s** (`TOKEN_TTL_SECONDS` in the plugin's env) — fine for a live demo, tune down for a tighter security story or up if your MCP round-trip is slow on stage.
- **No observability stack** — the original `tyk-demo` version could compose with an `opentelemetry-demo` deployment for Grafana dashboards; that's tyk-demo-specific tooling and wasn't ported here. Tyk's own gateway access logs (`kubectl logs deploy/gateway-tyk-oss-tyk-gateway`) are the audit trail for this port.
- **The plugin's RSA keypair is ephemeral** (regenerated on every pod restart) — fine since tokens live 60s, but means a restart invalidates any in-flight exchange. Not worth persisting for a demo.

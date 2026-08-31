"""acme-token-exchange-plugin — a Tyk OSS gRPC ("rich") coprocess plugin.

This replaces the ENTERPRISE-only Tyk "OAuth 2.0 Token Exchange" middleware
(RFC 8693) with a hand-rolled equivalent built on a feature that has been part
of Tyk's open source Community Edition gateway for years: gRPC/rich custom
plugins (https://tyk.io/docs/plugins/rich-plugins/grpc-plugins/). Same
observable behaviour, same governance story, no enterprise licence required.

Where it runs: as a "postPlugins" hook (`functionName: TokenExchangePostHook`)
on the acme-mcp-proxy Tyk OAS API. Tyk's own native JWT-auth middleware (JWKS
against Keycloak) has ALREADY authenticated the request by the time this hook
fires — that's a core, long-standing OSS gateway feature, not something this
plugin re-implements. This plugin only does the narrowing:

  1. Decode the (already-verified) inbound JWT to read `sub` and `entitlements`.
  2. Look at the JSON-RPC body to see which MCP tool is being called, and map
     that tool to the one OAuth scope it needs (customers:read/write,
     refunds:write).
  3. If the caller's entitlements don't cover that scope: short-circuit with a
     403 before the request ever reaches the MCP server or resource API.
  4. If they do: mint a brand-new, short-lived, self-signed JWT that KEEPS the
     caller's `sub` (this is impersonation, RFC 8693-style, not delegation —
     there's no `act` claim) but re-points `aud` at the resource API and
     narrows `scope` to exactly that one action. The inbound Authorization
     header is rewritten to carry this new token before Tyk proxies upstream.

The resource API (acme-resource-api) independently verifies this token's
signature against this plugin's own JWKS endpoint (served by this same
process on :8081) and enforces the narrowed scope again — see its own
comments for why that's not redundant.

⚠ Needs live verification against your actual Tyk Gateway build before demo
day (same spirit as this repo's other "⚠ verify" callouts):
  - Exact `hook_type`/hook dispatch semantics for `postPlugins` on OAS APIs —
    confirmed field names come from Tyk's public `apidef/oas/middleware.go`
    and the official Python sample_server.py, but the *end-to-end* wiring
    (gateway global coprocess config + this exact OAS shape) has not been
    exercised against a live gateway as part of this build.
  - Whether `request.body` (vs `request.raw_body`) carries the JSON-RPC text
    verbatim for this content type, and the precise semantics of
    `return_overrides.override_error` vs `response_body`.
  - Inbound header casing in `request.headers` (this code checks both
    "Authorization" and "authorization").
"""

import json
import base64
import binascii
import datetime
import logging
import os
import threading
import time
from concurrent import futures
from http.server import BaseHTTPRequestHandler, HTTPServer

import grpc
import jwt as pyjwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

import coprocess_object_pb2 as coprocess_object_pb2
import coprocess_object_pb2_grpc as coprocess_object_pb2_grpc

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("token-exchange-plugin")

HOOK_NAME = os.environ.get("HOOK_NAME", "TokenExchangePostHook")
GRPC_PORT = os.environ.get("GRPC_PORT", "5555")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8081"))
ISSUER = os.environ.get("TOKEN_ISSUER", "acme-token-exchange-plugin")
AUDIENCE = os.environ.get("TOKEN_AUDIENCE", "api.acme.internal")
AZP = os.environ.get("TOKEN_AZP", "tyk-mcp-gateway")
TOKEN_TTL_SECONDS = int(os.environ.get("TOKEN_TTL_SECONDS", "60"))
KID = "acme-plugin-key-1"

# Tool name -> the single OAuth scope that tool requires downstream. Mirrors
# the `security` requirement each operation carries in tyk/acme-api.oas.json.
TOOL_SCOPES = {
    "lookup_customer": "customers:read",
    "recent_orders": "customers:read",
    "update_customer": "customers:write",
    "issue_refund": "refunds:write",
}

# ---- RSA keypair (ephemeral — regenerated on every restart; tokens live <60s
# so nothing needs to survive a restart) -------------------------------------

_private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_private_pem = _private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
)


def _b64url_uint(n: int) -> str:
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _jwks_doc() -> dict:
    pub = _private_key.public_key().public_numbers()
    return {
        "keys": [
            {
                "kty": "RSA",
                "use": "sig",
                "alg": "RS256",
                "kid": KID,
                "n": _b64url_uint(pub.n),
                "e": _b64url_uint(pub.e),
            }
        ]
    }


# ---- JWT helpers -------------------------------------------------------------


def _b64url_decode(segment: str) -> bytes:
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def decode_unverified(token: str) -> dict:
    """Read the claims of a JWT Tyk's own auth middleware already verified."""
    parts = token.split(".")
    if len(parts) < 2:
        raise ValueError("not a JWT")
    return json.loads(_b64url_decode(parts[1]))


def mint_exchanged_token(sub: str, scope: str) -> str:
    now = int(time.time())
    payload = {
        "sub": sub,
        "aud": AUDIENCE,
        "azp": AZP,
        "scope": scope,
        "iss": ISSUER,
        "iat": now,
        "exp": now + TOKEN_TTL_SECONDS,
    }
    return pyjwt.encode(payload, _private_pem, algorithm="RS256", headers={"kid": KID})


def _header(headers_map, name: str) -> str:
    for k, v in headers_map.items():
        if k.lower() == name.lower():
            return v
    return ""


def _entitlements_set(claims: dict) -> set:
    raw = claims.get("entitlements", "")
    values = raw if isinstance(raw, list) else [raw]
    out = set()
    for v in values:
        out.update(str(v).split())
    return out


def _deny(request, code: int, error: str, **extra):
    body = json.dumps({"error": error, **extra})
    request.return_overrides.response_code = code
    request.return_overrides.response_error = error
    request.return_overrides.response_body = body
    request.return_overrides.override_error = True
    request.return_overrides.headers["Content-Type"] = "application/json"


def token_exchange_post_hook(obj):
    request = obj.request
    headers = dict(request.headers)
    bearer = _header(headers, "Authorization")
    if not bearer.lower().startswith("bearer "):
        _deny(request, 401, "missing_bearer_token")
        return obj
    raw_token = bearer.split(" ", 1)[1].strip()

    try:
        claims = decode_unverified(raw_token)
    except (ValueError, binascii.Error, json.JSONDecodeError) as exc:
        _deny(request, 401, "malformed_token", detail=str(exc))
        return obj

    sub = claims.get("sub", "")

    try:
        body = json.loads(request.body) if request.body else {}
    except json.JSONDecodeError:
        body = {}
    method = body.get("method", "")

    if method != "tools/call":
        # Only tool invocations get scope-checked and exchanged; tools/list,
        # initialize, etc. pass through on the original SSO token.
        return obj

    tool = (body.get("params") or {}).get("name", "")
    required_scope = TOOL_SCOPES.get(tool)
    if required_scope is None:
        _deny(request, 403, "unknown_tool", tool=tool)
        return obj

    entitlements = _entitlements_set(claims)
    if required_scope not in entitlements:
        log.info("DENY sub=%s tool=%s required=%s entitlements=%s", sub, tool, required_scope, sorted(entitlements))
        _deny(
            request,
            403,
            "insufficient_scope",
            tool=tool,
            required_scope=required_scope,
            entitlements=sorted(entitlements),
        )
        return obj

    exchanged = mint_exchanged_token(sub, required_scope)
    request.set_headers["Authorization"] = f"Bearer {exchanged}"
    log.info("EXCHANGE sub=%s tool=%s scope=%s -> aud=%s azp=%s", sub, tool, required_scope, AUDIENCE, AZP)
    return obj


class Dispatcher(coprocess_object_pb2_grpc.DispatcherServicer):
    def Dispatch(self, obj, context):
        if obj.hook_name == HOOK_NAME:
            try:
                obj = token_exchange_post_hook(obj)
            except Exception:  # noqa: BLE001 — never crash the gateway's request path
                log.exception("token_exchange_post_hook failed")
                _deny(obj.request, 500, "plugin_internal_error")
        return obj

    def DispatchEvent(self, event_wrapper, context):
        return coprocess_object_pb2.EventReply()


class _JWKSHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: A002 — quiet the default access log
        pass

    def do_GET(self):
        if self.path == "/.well-known/jwks.json":
            payload = json.dumps(_jwks_doc()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        elif self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()


def serve_jwks():
    server = HTTPServer(("0.0.0.0", HTTP_PORT), _JWKSHandler)
    log.info("JWKS server listening on :%d (/.well-known/jwks.json)", HTTP_PORT)
    server.serve_forever()


def serve_grpc():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    coprocess_object_pb2_grpc.add_DispatcherServicer_to_server(Dispatcher(), server)
    server.add_insecure_port(f"[::]:{GRPC_PORT}")
    server.start()
    log.info("gRPC coprocess dispatcher listening on :%s (hook_name=%s)", GRPC_PORT, HOOK_NAME)
    try:
        while True:
            time.sleep(86400)
    except KeyboardInterrupt:
        server.stop(0)


if __name__ == "__main__":
    threading.Thread(target=serve_jwks, daemon=True).start()
    serve_grpc()

#!/usr/bin/env python3
"""
agent.py — the minimal agent from the KCD "Deploy an Agent, Then Govern It" workshop.

It does two things, and only two things:
  1. Calls an LLM through Tyk AI Studio's OpenAI-compatible AI Gateway.
  2. Calls tools through an MCP server that is fronted by Tyk's MCP Gateway.

Neither the LLM provider nor the MCP server ever sees this script directly —
every call goes through a governed Tyk endpoint. That's the whole point of the demo:
the agent loop itself is boring and short; the interesting part is what's sitting
in front of it.

Config is via environment variables (see the lab guide, section 6.1):
  TYK_MCP_URL          e.g. http://localhost:8080/mcp-gw/mcp   (required)
  TYK_MCP_KEY          bearer key created for the MCP proxy in Tyk (required)
  AI_STUDIO_BASE_URL   e.g. http://localhost:9091/llm/call/workshop-llm/v1  (optional)
  AI_STUDIO_API_KEY    key/token issued for your AI Studio app credential (optional)
  AI_STUDIO_MODEL      the bare model name AI Studio should route to (optional)

If any of the three AI_STUDIO_* vars is missing, the script runs in MCP-only
mode: it discovers tools and calls one directly (no LLM in the loop) so the
tool-governance path can be demoed even when AI Studio isn't wired up yet.

Usage:
  python agent.py "How many users are in the system, and who is user 1?"
"""

import json
import os
import sys
import uuid

import httpx
from openai import OpenAI

MAX_TURNS = 6  # hard cap so a misbehaving loop can't run forever on stage


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"Missing required environment variable: {name}", file=sys.stderr)
        sys.exit(1)
    return value


def env_optional(name: str) -> str | None:
    return os.environ.get(name) or None


def _parse_mcp_body(resp: httpx.Response) -> dict:
    """Parse an MCP streamable-HTTP response body.

    The transport can reply as plain JSON or as a single SSE event
    ("event: message\\ndata: {...}") depending on server/version — this
    repo's Tyk-fronted MCP server does the latter. httpx's resp.json() only
    handles the former and raises JSONDecodeError on the SSE form, so try
    plain JSON first and fall back to pulling the JSON out of the first
    "data:" line.
    """
    try:
        return resp.json()
    except ValueError:
        pass
    for line in resp.text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            return json.loads(line[len("data:"):].strip())
    raise RuntimeError(f"could not parse MCP response body: {resp.text[:200]!r}")


class McpSession:
    """One streamable-HTTP MCP session against a Tyk-fronted MCP server.

    Streamable HTTP requires a real handshake before any other method works:
    initialize -> capture the Mcp-Session-Id response header -> send
    notifications/initialized with that header -> only then do tools/list or
    tools/call succeed. Skip this and every call comes back 200 OK with a
    JSON-RPC error body ("... invalid during session initialization"), which
    looks like nothing happened rather than like a real failure.
    """

    def __init__(self, mcp_url: str, mcp_key: str):
        self.mcp_url = mcp_url
        self.mcp_key = mcp_key
        self.session_id: str | None = None
        self._headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {mcp_key}",
            # Both media types must be offered — this is what the streamable-HTTP
            # transport actually checks; omit either and some servers 406.
            "Accept": "application/json, text/event-stream",
        }
        self._handshake()

    def _post(self, payload: dict, *, expect_body: bool = True) -> dict | None:
        headers = dict(self._headers)
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        resp = httpx.post(self.mcp_url, json=payload, headers=headers, timeout=30.0)
        resp.raise_for_status()
        if not self.session_id:
            sid = resp.headers.get("Mcp-Session-Id")
            if sid:
                self.session_id = sid
        if not expect_body or not resp.text.strip():
            return None
        return _parse_mcp_body(resp)

    def _handshake(self) -> None:
        self._post(
            {
                "jsonrpc": "2.0",
                "id": str(uuid.uuid4()),
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "kcd-workshop-agent", "version": "1.0"},
                },
            }
        )
        if not self.session_id:
            raise RuntimeError(
                "MCP server did not return an Mcp-Session-Id header from initialize — "
                "cannot proceed with the streamable-HTTP handshake"
            )
        # A notification carries no "id" and gets a bodyless 202 in response.
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect_body=False)

    def call(self, method: str, params: dict | None = None) -> dict:
        """Send one JSON-RPC 2.0 request over the established session."""
        body = self._post(
            {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params or {}}
        )
        if body is None:
            return {}
        if "error" in body:
            raise RuntimeError(f"MCP error calling {method}: {body['error']}")
        return body.get("result", {})


def mcp_tools_to_openai_tools(mcp_tools: list[dict]) -> list[dict]:
    """Convert MCP's tools/list shape into OpenAI's function-calling tool shape.

    This is what makes "filtered discovery" visible in the demo: whatever list
    Tyk lets this particular key see is the only set of tools the model is ever
    told about. A key scoped to fewer tools produces a visibly shorter list here.
    """
    openai_tools = []
    for tool in mcp_tools:
        openai_tools.append(
            {
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool.get("description", ""),
                    "parameters": tool.get("inputSchema", {"type": "object", "properties": {}}),
                },
            }
        )
    return openai_tools


def run_mcp_only(session: McpSession, tool_names: list[str]) -> None:
    """Demo the governed tool path with no LLM in the loop.

    Used when AI_STUDIO_* isn't fully configured — there's no model here to
    decide which tool to call, so this just calls one directly to prove the
    governed path (auth, and whatever else the gateway enforces) still works.
    """
    print(
        "\n[agent] AI_STUDIO_BASE_URL / AI_STUDIO_API_KEY / AI_STUDIO_MODEL aren't all "
        "set — running MCP-only (no LLM call). This demos the tool-governance path in "
        "isolation; set all three AI_STUDIO_* vars for the full agent loop."
    )
    if not tool_names:
        print("[agent] No tools visible with this key — nothing to demo.")
        return
    demo_tool = "get_anything" if "get_anything" in tool_names else tool_names[0]
    print(f"\n[mcp] calling '{demo_tool}' directly (no LLM to pick it) to prove the governed path works ...")
    try:
        result = session.call("tools/call", {"name": demo_tool, "arguments": {}})
        print(json.dumps(result, indent=2))
    except (httpx.HTTPStatusError, RuntimeError) as exc:
        print(f"[mcp] tool call failed (this may be the governance layer at work): {exc}")


def run(question: str) -> None:
    mcp_url = env("TYK_MCP_URL")
    mcp_key = env("TYK_MCP_KEY")

    ai_base_url = env_optional("AI_STUDIO_BASE_URL")
    ai_api_key = env_optional("AI_STUDIO_API_KEY")
    ai_model = env_optional("AI_STUDIO_MODEL")
    mcp_only = not (ai_base_url and ai_api_key and ai_model)

    print(f"[mcp] discovering tools via {mcp_url} (through Tyk MCP Gateway) ...")
    session = McpSession(mcp_url, mcp_key)
    discovery = session.call("tools/list")
    mcp_tools = discovery.get("tools", [])
    tool_names = [t["name"] for t in mcp_tools]
    print(f"[mcp] this key can see {len(tool_names)} tool(s): {tool_names}")

    if mcp_only:
        run_mcp_only(session, tool_names)
        return

    tools = mcp_tools_to_openai_tools(mcp_tools)
    client = OpenAI(base_url=ai_base_url, api_key=ai_api_key)

    messages = [
        {
            "role": "system",
            "content": (
                "You are a helpful assistant with access to tools. "
                "Use a tool whenever it would help answer the question accurately, "
                "rather than guessing."
            ),
        },
        {"role": "user", "content": question},
    ]

    for turn in range(MAX_TURNS):
        print(f"\n[llm] turn {turn + 1}: calling {ai_model} via Tyk AI Studio ...")
        response = client.chat.completions.create(
            model=ai_model,
            messages=messages,
            tools=tools if tools else None,
        )
        message = response.choices[0].message
        messages.append(message.model_dump(exclude_none=True))

        if not message.tool_calls:
            print("\n=== final answer ===")
            print(message.content)
            return

        for tool_call in message.tool_calls:
            name = tool_call.function.name
            try:
                arguments = json.loads(tool_call.function.arguments or "{}")
            except json.JSONDecodeError:
                arguments = {}

            print(f"[mcp] model requested tool '{name}' with args {arguments}")
            try:
                result = session.call("tools/call", {"name": name, "arguments": arguments})
                content = json.dumps(result)
            except (httpx.HTTPStatusError, RuntimeError) as exc:
                # A 429 here is the rate-limit governance beat from the guide (section 6.4) —
                # feed the error back to the model instead of crashing the demo.
                content = json.dumps({"error": str(exc)})
                print(f"[mcp] tool call failed (this may be the governance layer at work): {exc}")

            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tool_call.id,
                    "content": content,
                }
            )

    print("\n[agent] hit MAX_TURNS without a final answer — stopping.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} \"<question>\"", file=sys.stderr)
        sys.exit(1)
    run(" ".join(sys.argv[1:]))

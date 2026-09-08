#!/usr/bin/env python3
"""The caller's tools, offered to the CLI as an MCP server.

WHY
---
The bridge (agy_shim.py) uses a coding-agent CLI as the model behind an agent
framework. The framework's tools have to reach the model somehow. Written as a
JSON protocol in the prompt, the model kept calling them natively anyway —
and with no function declared, every native call failed as "improperly
formatted" (140 retries in two days, half the quota). Offered as REAL tools
through this server, the model calls them natively and correctly (E8,
docs/research/agy-cli.md, 2026-09-09).

WHAT IT DOES
------------
The CLI starts this server once per conversation and asks for the tool list
once, at start. The list is whatever `tools.json` in the current directory
says — the bridge writes that file into the per-conversation working
directory before spawning the CLI, and the CLI spawns this server with that
directory as its cwd. So one global server entry serves every bot with its
own tools.

A call is NOT executed here. The framework executes tools, under its own
approval rules. This server validates the arguments against the schema — a
missing one comes back as an error the model corrects within the same turn —
records the valid call in `calls.jsonl` next to the tools file, and answers
with a handoff note. The bridge watches the CLI's step events and hands the
turn's valid calls to the framework — several of them together when the model
made several that do not depend on each other.

Standard library only, one file, like the bridge.
"""
from __future__ import annotations

import json
import os
import sys
import time
from typing import Any, Dict, List, Optional

PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "tools"
VERSION = "0.1.0"
TOOLS_FILE = "tools.json"
CALLS_FILE = "calls.jsonl"
HANDOFF = ("Accepted: the caller runs this call and sends its result as the next message. "
           "You may add further calls now, but ONLY ones that do not need this result — they travel together and save a round trip. "
           "Do not answer the question yet; when you have nothing more to call, end your turn with the single word: pending")

_TYPES = {"string": str, "integer": int, "number": (int, float), "boolean": bool, "array": list, "object": dict}


def log(msg: str) -> None:
    sys.stderr.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} tools-mcp {msg}\n")
    sys.stderr.flush()


def load_tools(directory: str) -> List[Dict[str, Any]]:
    """The caller's function specs (OpenAI shape: name, description,
    parameters) from tools.json in DIRECTORY; none when the file is absent —
    a CLI started for something else (the model catalog) gets no tools."""
    path = os.path.join(directory, TOOLS_FILE)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    out = []
    for t in data if isinstance(data, list) else []:
        fn = (t or {}).get("function") or t or {}
        if fn.get("name"):
            out.append({"name": fn["name"], "description": fn.get("description") or "", "parameters": fn.get("parameters") or {}})
    return out


def mcp_tool(fn: Dict[str, Any]) -> Dict[str, Any]:
    schema = dict(fn.get("parameters") or {})
    schema.setdefault("type", "object")
    schema.setdefault("properties", {})
    return {"name": fn["name"], "description": fn.get("description") or "", "inputSchema": schema}


def validate(args: Any, schema: Dict[str, Any]) -> List[str]:
    """Required keys, unknown keys (when the schema forbids them), scalar and
    container types — enough to send the model a precise correction."""
    if not isinstance(args, dict):
        return ["arguments must be an object"]
    problems = []
    props = schema.get("properties") or {}
    for key in schema.get("required") or []:
        if key not in args or args[key] is None or args[key] == "":
            problems.append(f"missing required '{key}'")
    if schema.get("additionalProperties") is False:
        for key in args:
            if key not in props:
                problems.append(f"unknown argument '{key}'")
    for key, val in args.items():
        spec = props.get(key) or {}
        want = spec.get("type")
        if val is None or not want or want not in _TYPES:
            continue
        ok = isinstance(val, _TYPES[want])
        if want in ("integer", "number") and isinstance(val, bool):
            ok = False
        if not ok:
            problems.append(f"'{key}' must be {want}")
        elif "enum" in spec and val not in spec["enum"]:
            problems.append(f"'{key}' must be one of {spec['enum']}")
    return problems


def record_call(directory: str, name: str, arguments: Dict[str, Any]) -> None:
    with open(os.path.join(directory, CALLS_FILE), "a", encoding="utf-8") as f:
        f.write(json.dumps({"t": time.time(), "name": name, "arguments": arguments}, ensure_ascii=False) + "\n")


class Server:
    def __init__(self, directory: str):
        self.directory = directory

    def handle(self, msg: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize":
            return self._ok(msg_id, {"protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
                                     "capabilities": {"tools": {"listChanged": False}},
                                     "serverInfo": {"name": SERVER_NAME, "version": VERSION},
                                     "instructions": "The caller's tools. Call them with every required argument; the result arrives as the next message."})
        if msg_id is None:
            return None                                  # a notification
        if method == "ping":
            return self._ok(msg_id, {})
        if method == "tools/list":
            return self._ok(msg_id, {"tools": [mcp_tool(fn) for fn in load_tools(self.directory)]})
        if method == "tools/call":
            return self._call(msg_id, params)
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"method not found: {method}"}}

    def _call(self, msg_id: Any, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params.get("name")
        args = params.get("arguments") or {}
        fn = next((t for t in load_tools(self.directory) if t["name"] == name), None)
        if fn is None:
            return self._ok(msg_id, self._content(f"unknown tool: {name}", True))
        problems = validate(args, mcp_tool(fn)["inputSchema"])
        if problems:
            return self._ok(msg_id, self._content("invalid arguments: " + "; ".join(problems), True))
        record_call(self.directory, str(name), args)
        return self._ok(msg_id, self._content(HANDOFF, False))

    @staticmethod
    def _content(text: str, is_error: bool) -> Dict[str, Any]:
        return {"content": [{"type": "text", "text": text}], "isError": is_error}

    @staticmethod
    def _ok(msg_id: Any, result: Any) -> Dict[str, Any]:
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    def serve(self) -> None:
        tools = load_tools(self.directory)
        log(f"serving {len(tools)} tool(s) from {self.directory}")
        out = sys.stdout
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                out.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}) + "\n")
                out.flush()
                continue
            reply = self.handle(msg)
            if reply is not None:
                out.write(json.dumps(reply, ensure_ascii=False) + "\n")
                out.flush()


if __name__ == "__main__":
    try:
        Server(os.getcwd()).serve()
    except KeyboardInterrupt:
        pass

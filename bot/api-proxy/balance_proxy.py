#!/usr/bin/env python3
"""A pass-through proxy for a hosted OpenAI-compatible API that appends the
account's remaining balance to every final answer.

The gateway talks to this on loopback instead of the provider. Every request
is forwarded unchanged — same path, same body, the caller's own Authorization
header. Only one thing is added: when a chat completion ends as a message to
the user (finish_reason "stop", no tool calls), the reply gets one more line,
"(DeepSeek-Guthaben: 18.42 USD)". Tool-call turns are left alone; the user
never sees those.

The balance comes from the provider's own balance endpoint, fetched with the
same key the request carried and cached for a short while. Nothing here costs
tokens: the endpoint is free, and the footer travels in the caller's history
as a dozen tokens per turn.

Standard library only, like the bridge next door.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple

log = logging.getLogger("balance-proxy")

# What we know about the providers with a balance endpoint. `extract` turns the
# endpoint's JSON into (amount, currency); `hop` headers never cross the proxy.
PROVIDERS: Dict[str, Dict[str, Any]] = {
    "deepseek": {
        "upstream": "https://api.deepseek.com",
        "balance_path": "/user/balance",
        "label": "DeepSeek",
    },
    "moonshot": {
        "upstream": "https://api.moonshot.ai",
        "balance_path": "/v1/users/me/balance",
        "label": "Kimi",
    },
}
HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization",
               "proxy-authenticate", "host", "content-length", "accept-encoding"}

FOOTER_RE = re.compile(r"^\s*\((?:[A-Za-z0-9 ._-]+)-Guthaben:[^)\n]*\)\s*$", re.M)


def extract_balance(provider: str, payload: Dict[str, Any]) -> Tuple[str, str]:
    """(amount, currency) from a provider's balance JSON, or raise ValueError."""
    if provider == "deepseek":
        infos = payload.get("balance_infos") or []
        if not infos:
            raise ValueError("no balance_infos in the answer")
        info = infos[0]
        return str(info.get("total_balance") or info.get("topped_up_balance") or "?"), str(info.get("currency") or "")
    if provider == "moonshot":
        data = payload.get("data") or {}
        if "available_balance" not in data:
            raise ValueError("no available_balance in the answer")
        return str(data["available_balance"]), "CNY"
    raise ValueError(f"unknown provider {provider}")


def footer_text(label: str, amount: str, currency: str) -> str:
    return f"({label}-Guthaben: {amount} {currency})".replace("  ", " ").replace(" )", ")")


def strip_model_footer(text: str) -> str:
    """Models copy patterns: a balance line the model wrote itself goes."""
    return FOOTER_RE.sub("", text).rstrip()


def append_footer_json(body: Dict[str, Any], footer: str) -> Dict[str, Any]:
    """A non-streamed completion: the footer on the final message, else untouched."""
    choices = body.get("choices") or []
    if not choices:
        return body
    ch = choices[0]
    msg = ch.get("message") or {}
    if ch.get("finish_reason") != "stop" or msg.get("tool_calls") or not isinstance(msg.get("content"), str):
        return body
    msg["content"] = strip_model_footer(msg["content"]) + "\n\n" + footer
    return body


def inject_footer_sse(lines: Iterable[str], footer: str) -> Iterator[str]:
    """A streamed completion, line by line. The chunk that carries
    finish_reason is held back; if the turn ends as a message (stop, no tool
    calls seen), one content chunk with the footer goes out before it."""
    held: Optional[str] = None
    saw_tool_call = False
    template: Optional[Dict[str, Any]] = None
    for line in lines:
        if not line.startswith("data:"):
            yield line
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            if held is not None:
                yield held
                held = None
            yield line
            continue
        try:
            obj = json.loads(payload)
        except ValueError:
            yield line
            continue
        choices = obj.get("choices") or []
        ch = choices[0] if choices else {}
        delta = ch.get("delta") or {}
        if delta.get("tool_calls"):
            saw_tool_call = True
        if template is None and obj.get("id"):
            template = {k: obj[k] for k in ("id", "object", "created", "model") if k in obj}
        if ch.get("finish_reason"):
            if ch["finish_reason"] == "stop" and not saw_tool_call and template is not None:
                extra = dict(template, choices=[{"index": ch.get("index", 0), "delta": {"content": "\n\n" + footer}, "finish_reason": None}])
                yield "data: " + json.dumps(extra, ensure_ascii=False) + "\n\n"
            held = line          # the finish chunk closes the message after our line
            continue
        yield line
    if held is not None:
        yield held


class Balance:
    """The provider's balance, fetched with the caller's key, cached briefly."""

    def __init__(self, provider: str, upstream: str, ttl: float):
        self.provider, self.upstream, self.ttl = provider, upstream, ttl
        self.path = PROVIDERS[provider]["balance_path"]
        self.label = PROVIDERS[provider]["label"]
        self._cache: Dict[str, Tuple[float, str]] = {}
        self._lock = threading.Lock()

    def footer(self, authorization: str) -> str:
        key = hashlib.sha256(authorization.encode()).hexdigest()[:16]
        with self._lock:
            hit = self._cache.get(key)
            if hit and hit[0] > time.time():
                return hit[1]
        try:
            req = urllib.request.Request(self.upstream + self.path, headers={"Authorization": authorization, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                amount, currency = extract_balance(self.provider, json.loads(resp.read().decode("utf-8")))
            text = footer_text(self.label, amount, currency)
        except Exception as exc:  # noqa: BLE001 — the answer must not fail because the balance did
            log.warning("balance unavailable: %s", str(exc)[:160])
            text = footer_text(self.label, "unbekannt", "")
        with self._lock:
            self._cache[key] = (time.time() + self.ttl, text)
        return text


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    balance: Balance = None  # type: ignore[assignment]
    started = time.time()

    def log_message(self, fmt, *a):  # quiet access log; errors still surface
        return

    def _forward_headers(self) -> Dict[str, str]:
        out = {}
        for k, v in self.headers.items():
            if k.lower() in HOP_HEADERS:
                continue
            out[k] = v
        out["Accept-Encoding"] = "identity"
        return out

    def do_GET(self):
        if self.path == "/healthz":
            body = json.dumps({"status": "ok", "provider": self.balance.provider, "upstream": self.upstream,
                               "uptime_s": int(time.time() - self.started)}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
            return
        self._proxy(None)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._proxy(self.rfile.read(length) if length else b"")

    def _proxy(self, body: Optional[bytes]) -> None:
        req = urllib.request.Request(self.upstream + self.path, data=body, headers=self._forward_headers(), method=self.command)
        wants_stream = False
        is_chat = self.path.rstrip("/").endswith("/chat/completions") and body is not None
        if is_chat:
            try:
                wants_stream = bool(json.loads(body.decode("utf-8")).get("stream"))
            except ValueError:
                is_chat = False
        try:
            resp = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as err:
            data = err.read()
            self.send_response(err.code)
            for k, v in err.headers.items():
                if k.lower() not in HOP_HEADERS:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        except Exception as exc:  # noqa: BLE001
            data = json.dumps({"error": {"message": f"upstream unreachable: {exc}", "type": "server_error"}}).encode()
            self.send_response(502); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data)
            return

        with resp:
            authorization = self.headers.get("Authorization") or ""
            if is_chat and wants_stream and resp.status == 200:
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in HOP_HEADERS:
                        self.send_header(k, v)
                self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
                footer = self.balance.footer(authorization)
                try:
                    for out in inject_footer_sse(_sse_lines(resp), footer):
                        chunk = out.encode("utf-8")
                        self.wfile.write(f"{len(chunk):x}\r\n".encode()); self.wfile.write(chunk); self.wfile.write(b"\r\n")
                    self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    log.info("client disconnected mid-stream")
                return
            data = resp.read()
            if is_chat and resp.status == 200:
                try:
                    obj = json.loads(data.decode("utf-8"))
                    data = json.dumps(append_footer_json(obj, self.balance.footer(authorization)), ensure_ascii=False).encode("utf-8")
                except ValueError:
                    pass
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in HOP_HEADERS and k.lower() != "content-type":
                    self.send_header(k, v)
            self.send_header("Content-Type", resp.headers.get("Content-Type") or "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


def _sse_lines(resp) -> Iterator[str]:
    """The upstream stream as SSE lines, each with its trailing newlines kept:
    a `data:` line plus the blank line that ends the event."""
    buf = b""
    while True:
        chunk = resp.read(4096)
        if not chunk:
            break
        buf += chunk
        while b"\n\n" in buf:
            event, buf = buf.split(b"\n\n", 1)
            yield event.decode("utf-8", "replace") + "\n\n"
    if buf.strip():
        yield buf.decode("utf-8", "replace") + "\n\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--provider", choices=sorted(PROVIDERS), required=True)
    ap.add_argument("--upstream", default="", help="override the provider's base URL")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--cache", type=float, default=60.0, help="seconds a fetched balance is reused")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-5s %(message)s", stream=sys.stderr)
    upstream = (args.upstream or PROVIDERS[args.provider]["upstream"]).rstrip("/")
    Handler.upstream = upstream
    Handler.balance = Balance(args.provider, upstream, args.cache)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    log.info("balance proxy for %s -> %s on http://%s:%d (cache %.0fs)", args.provider, upstream, args.host, args.port, args.cache)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

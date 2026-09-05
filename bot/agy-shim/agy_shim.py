#!/usr/bin/env python3
"""
An OpenAI-compatible endpoint backed by a coding-agent CLI.

WHY THIS EXISTS
---------------
The CLI authenticates against a subscription rather than a metered API key, but
it speaks its own protocol and knows nothing about chat completions. This bridges
the two so an agent framework can use it as an ordinary provider.

WHY A PERSISTENT PROCESS PER CONVERSATION
-----------------------------------------
Measured on the target CLI, same three-turn exchange:

    separate process per turn      one process, stream-json
    turn 2   +14,120 tokens        turn 2   +5,863   cache_read  8,124
    turn 3   +14,335 tokens        turn 3   +5,945   cache_read 16,242
             cache flat at 8,131            cache grows with the conversation

A fresh process re-sends its whole toolset (57 tool definitions, ~14k tokens)
uncached on every turn. A living process gets an incrementally cached prefix, so
the marginal turn costs roughly 40% of what it otherwise would, and the gap
widens as the conversation grows.

That is the entire reason this is more complicated than a subprocess call.

THE IMPEDANCE MISMATCH
----------------------
Chat-completions is stateless: the caller sends the full history every time.
The CLI is stateful: it wants one new message per turn. So this keeps a process
per conversation, feeds it the history once at startup, and thereafter forwards
only what is new. Conversations are identified by hashing their opening
messages, which stay stable while the tail grows.

CONTEXT GROWTH
--------------
Roughly 6k tokens accumulate per turn, so a long conversation eventually reaches
the context limit. Past a threshold the process is asked to summarise itself, is
replaced, and the summary is fed to its successor. Cost resets; continuity
survives in compressed form.
"""

from __future__ import annotations

import argparse
import hashlib
import base64
import binascii
import json
import logging
import os
import queue
import re
import shutil
import subprocess
import tempfile
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("agy-shim")


# ---------------------------------------------------------------------------
# One conversation, one CLI process
# ---------------------------------------------------------------------------

class AgentProcess:
    """A living CLI process holding one conversation.

    Output is drained by a reader thread. Without that, a process writing more
    than a pipe buffer while nobody reads it deadlocks — and the failure looks
    like the model being slow rather than like a bug here.
    """

    def __init__(self, binary: str, model: str, workdir: str, extra_args: list[str], agents_md: str = ""):
        self.model = model
        # Its own directory, and destroyed with it.
        #
        # This is not tidiness. In stream-json mode the CLI continues the most
        # recent conversation belonging to its working directory, so processes
        # sharing one directory inherit each other's history — observed as a
        # fresh process reporting turn 5 with 24k tokens already cached. For a
        # multi-channel assistant that means one conversation's content
        # surfacing in another's replies.
        self.workdir = tempfile.mkdtemp(prefix="agy-shim-", dir=workdir)
        # AGENTS.md in the working directory is read by the CLI as its
        # project instructions — system level, unlike anything we can put in a
        # user turn. This is where the bot's identity and the tool protocol's
        # "you have no tools" actually stick.
        if agents_md:
            with open(os.path.join(self.workdir, "AGENTS.md"), "w", encoding="utf-8") as f:
                f.write(agents_md)
        self.created = time.time()
        self.last_used = self.created
        self.turns = 0
        self.input_tokens = 0        # from the most recent turn, not a sum:
                                     # the CLI reports cumulative context size
        self.lock = threading.Lock()
        self._closed = False

        cmd = [binary, "--input-format", "stream-json",
               "--output-format", "stream-json", "--model", model] + extra_args
        log.debug("spawning: %s", " ".join(cmd))

        self.proc = subprocess.Popen(
            cmd, cwd=self.workdir,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
            # A clean environment except for what the CLI needs to find its own
            # credentials. HOME is what decides which account it runs as.
            env={k: v for k, v in os.environ.items()
                 if k in ("HOME", "PATH", "USER", "LOGNAME", "LANG", "TERM")},
        )

        self._events: queue.Queue = queue.Queue()
        self._stderr_tail: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        self.conversation_id = None
        self.tool_count = None
        self.pending_prefix = ""
        self._await_init()

    # -- plumbing -----------------------------------------------------------

    def _read_stdout(self):
        try:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    self._events.put(json.loads(line))
                except json.JSONDecodeError:
                    log.debug("non-json on stdout: %s", line[:120])
        except Exception:
            pass
        finally:
            self._events.put(None)          # sentinel: the process is gone

    def _read_stderr(self):
        try:
            for line in self.proc.stderr:
                self._stderr_tail = (self._stderr_tail + [line.rstrip()])[-20:]
        except Exception:
            pass

    def _await_init(self, timeout: float = 60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                ev = self._events.get(timeout=deadline - time.time())
            except queue.Empty:
                break
            if ev is None:
                raise RuntimeError(f"process exited during startup: {self.stderr_tail()}")
            if ev.get("event") == "init":
                init = ev.get("init", {})
                self.conversation_id = ev.get("conversation_id")
                self.tool_count = len(init.get("tools", []))
                log.info("started conversation %s (model=%s, %s tools)",
                         (self.conversation_id or "?")[:8], init.get("model"), self.tool_count)
                return
        raise RuntimeError(f"no init event within {timeout}s: {self.stderr_tail()}")

    def stderr_tail(self) -> str:
        return " | ".join(self._stderr_tail[-3:]) or "(no stderr)"

    def alive(self) -> bool:
        return not self._closed and self.proc.poll() is None

    # -- the actual work ----------------------------------------------------

    # Sent once when the CLI reached for one of its own tools and was denied:
    # the turn is lost, but the conversation is not, and a reminder recovers it
    # far more often than not.
    TOOL_REMINDER = (
        "REMINDER: your built-in tools are disabled and that attempt was denied. "
        "Do not run commands or read files. Answer now with exactly one JSON "
        "object per the TOOL PROTOCOL — a tool_call from the listed functions, "
        "or a message.")

    def turn(self, content: str, timeout: float, _retry: bool = True) -> dict:
        """Send one message, wait for its result. Caller must hold self.lock."""
        if not self.alive():
            raise RuntimeError(f"process is not running: {self.stderr_tail()}")

        msg = {"event": "user", "message": {"role": "user", "content": content}}
        try:
            self.proc.stdin.write(json.dumps(msg) + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError) as exc:
            raise RuntimeError(f"could not write to process: {exc}") from exc

        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError(f"no result within {timeout}s")
            try:
                ev = self._events.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError(f"no result within {timeout}s")
            if ev is None:
                raise RuntimeError(f"process exited mid-turn: {self.stderr_tail()}")
            if ev.get("event") != "result":
                continue

            result = ev.get("result", {})
            usage = result.get("usage", {}) or {}
            self.turns += 1
            self.last_used = time.time()
            self.input_tokens = usage.get("input_tokens", 0) or 0

            if result.get("status") != "SUCCESS":
                raise RuntimeError(result.get("error") or self.stderr_tail())

            # A denied tool permission is reported as success with no text: the
            # CLI abandons the turn rather than answering with what it has. That
            # surfaced as an unexplained failure, so say what actually happened.
            if not str(result.get("response", "")).strip():
                detail = self.stderr_tail()
                if "permission" in detail.lower():
                    if _retry:
                        # The whole operating context again, not just a nudge:
                        # a fresh conversation that reached for its own tools
                        # answered the nudge from its default persona, with the
                        # system prompt apparently already out of mind.
                        log.warning("model reached for a denied built-in tool; re-sending the operating context once")
                        again = getattr(self, "full_prefix", "")
                        return self.turn((again + "\n\n" if again else "") + self.TOOL_REMINDER,
                                         max(30.0, deadline - time.time()), _retry=False)
                    raise RuntimeError(
                        "the model needed a tool it is not permitted to use, and "
                        "produced no answer even after the reminder. " + detail)
                raise RuntimeError("the model returned an empty response. " + detail)
            return result

    def close(self):
        self._closed = True
        shutil.rmtree(getattr(self, "workdir", "") or "/nonexistent", ignore_errors=True)
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# The pool
# ---------------------------------------------------------------------------

SUMMARY_REQUEST = (
    "Summarise this entire conversation so far for your own future reference. "
    "Keep every fact, decision, name, number and open question that a "
    "continuation would need. Write prose, no preamble, at most 400 words."
)


class Pool:
    def __init__(self, args):
        self.args = args
        self.procs: dict[str, AgentProcess] = {}
        self.spares: dict[str, AgentProcess] = {}   # pre-warmed, stateless mode
        self.lock = threading.Lock()
        self.slots = threading.Semaphore(args.max_concurrent)
        threading.Thread(target=self._reaper, daemon=True).start()

    def _reaper(self):
        """Retire idle conversations so a day of traffic does not leave dozens
        of processes holding context nobody is going to continue."""
        while True:
            time.sleep(30)
            cutoff = time.time() - self.args.idle_timeout
            with self.lock:
                stale = [k for k, p in self.procs.items()
                         if p.last_used < cutoff or not p.alive()]
                for key in stale:
                    log.info("retiring conversation %s (idle or dead)", key[:8])
                    self.procs.pop(key).close()

    def _get_or_start(self, key: str, seed: list[str], system: str,
                      model: str) -> AgentProcess:
        with self.lock:
            proc = self.procs.get(key)
            if proc and proc.alive():
                return proc
            if proc:
                log.warning("conversation %s had died; restarting", key[:8])
                proc.close()
                self.procs.pop(key, None)

            if len(self.procs) >= self.args.max_processes:
                oldest = min(self.procs.items(), key=lambda kv: kv[1].last_used)
                log.info("process limit reached; retiring %s", oldest[0][:8])
                self.procs.pop(oldest[0]).close()

            proc = AgentProcess(self.args.binary, model,
                                self.args.workdir, self.args.extra_args,
                                agents_md=agents_md_text(system))
            self.procs[key] = proc

        # Seeding costs a model round-trip, so it happens only when there is
        # genuine prior conversation to replay — and outside the pool lock,
        # which would otherwise block every other conversation meanwhile.
        if seed:
            with proc.lock:
                proc.turn(self._seed_message(seed, system), self.args.timeout)
            log.info("seeded conversation %s with %d prior messages", key[:8], len(seed))
        else:
            # Nothing to replay: the system prompt rides along with the first
            # real message instead of burning a turn of its own.
            # The CLI has an identity of its own and answers "who are you" with
            # it unless told, in the conversation, that here it acts as someone
            # else. The frame makes the agent's system prompt (which carries the
            # bot's name from SOUL.md) the authority on that.
            proc.pending_prefix = IDENTITY_FRAME_HEAD + system + IDENTITY_FRAME_TAIL
            proc.full_prefix = proc.pending_prefix       # kept for the reminder
            proc.identity = identity_name(system)
        return proc

    @staticmethod
    def _seed_message(history: list[str], system: str) -> str:
        head = ("These are your standing instructions:\n\n" + system + "\n\n") if system else ""
        return (
            head + "Here is the conversation so far, for context. Read it and "
            "reply with just: ready\n\n" + "\n\n".join(history)
        )

    def _compact(self, key: str, proc: AgentProcess) -> AgentProcess:
        """Replace a process whose context has grown too large, carrying a
        summary across. Cost resets; continuity survives in compressed form."""
        log.info("compacting %s at %d input tokens after %d turns",
                 key[:8], proc.input_tokens, proc.turns)
        try:
            summary = proc.turn(SUMMARY_REQUEST, self.args.timeout).get("response", "")
        except Exception as exc:
            log.warning("could not summarise %s (%s); starting clean", key[:8], exc)
            summary = ""
        proc.close()

        with self.lock:
            self.procs.pop(key, None)
            fresh = AgentProcess(self.args.binary, proc.model,
                                 self.args.workdir, self.args.extra_args)
            self.procs[key] = fresh

        if summary.strip():
            with fresh.lock:
                fresh.turn(
                    "This continues an earlier conversation. Here is a summary "
                    "of it. Reply with just: ready\n\n" + summary,
                    self.args.timeout)
        return fresh

    # -- stateless: one fresh CLI conversation per request ---------------------
    def _spawn(self, model: str) -> AgentProcess:
        return AgentProcess(self.args.binary, model, self.args.workdir,
                            self.args.extra_args, agents_md=agents_md_text(""))

    def _take_spare(self, model: str) -> AgentProcess:
        """A pre-warmed process for this model, or a fresh one. Start-up is the
        one cost of statelessness, so the next process is started right after
        one is taken."""
        with self.lock:
            proc = self.spares.pop(model, None)
        if proc is None or not proc.alive():
            proc = self._spawn(model)
        threading.Thread(target=self._warm, args=(model,), daemon=True).start()
        return proc

    def _warm(self, model: str):
        try:
            fresh = self._spawn(model)
        except Exception as exc:  # noqa: BLE001
            log.warning("could not pre-warm a process for %s: %s", model, exc)
            return
        with self.lock:
            old = self.spares.get(model)
            self.spares[model] = fresh
        if old is not None:
            old.close()

    def _complete_stateless(self, history: list[str], message: str,
                            system: str, model: str,
                            images: list[tuple[bytes, str]]) -> tuple[str, dict, dict]:
        proc = self._take_spare(model)
        try:
            text = stateless_message(system, history, message)
            if images:
                text = place_images(text, images, proc.workdir)
            proc.full_prefix = text          # re-sent whole if a built-in tool is denied
            proc.identity = identity_name(system)
            started = time.time()
            with proc.lock:
                result = proc.turn(text, self.args.timeout)
            usage = result.get("usage", {}) or {}
            log.info("stateless [%s] history=%d in=%s cached=%s out=%s %.1fs",
                     model, len(history), usage.get("input_tokens"),
                     usage.get("cache_read_tokens"), usage.get("output_tokens"),
                     time.time() - started)
            return result.get("response", ""), usage, {"turns": 1, "model": model}
        finally:
            threading.Thread(target=proc.close, daemon=True).start()

    def complete(self, key: str, history: list[str], message: str,
                 system: str = "", model: str = "",
                 images: list[tuple[bytes, str]] | None = None) -> tuple[str, dict, dict]:
        acquired = self.slots.acquire(timeout=self.args.queue_timeout)
        if not acquired:
            raise TimeoutError("too many conversations in flight")
        try:
            if self.args.stateless:
                return self._complete_stateless(history, message, system, model, images or [])
            proc = self._get_or_start(key, history, system, model)

            # A first turn on a fresh conversation carries the system prompt.
            prefix = getattr(proc, "pending_prefix", "")
            message = identity_line(getattr(proc, "identity", "")) + message
            if prefix:
                message = prefix + "\n\n" + message
                proc.pending_prefix = ""

            if proc.input_tokens >= self.args.compact_at:
                proc = self._compact(key, proc)

            started = time.time()
            with proc.lock:
                result = proc.turn(message, self.args.timeout)
            usage = result.get("usage", {}) or {}

            log.info(
                "%s [%s] turn=%d in=%s cached=%s out=%s %.1fs",
                key[:8], proc.model, proc.turns, usage.get("input_tokens"),
                usage.get("cache_read_tokens"), usage.get("output_tokens"),
                time.time() - started,
            )
            return result.get("response", ""), usage, {"turns": proc.turns,
                                                       "model": proc.model}
        finally:
            self.slots.release()

    def stats(self) -> dict:
        with self.lock:
            return {
                "mode": "stateless" if self.args.stateless else "stateful",
                "spares": sorted(self.spares),
                "conversations": len(self.procs),
                "detail": [
                    {"key": k[:8], "model": p.model, "turns": p.turns,
                     "input_tokens": p.input_tokens,
                     "alive": p.alive(), "idle_s": round(time.time() - p.last_used)}
                    for k, p in self.procs.items()
                ],
            }


# ---------------------------------------------------------------------------
# Chat-completions surface
# ---------------------------------------------------------------------------

def conversation_key(messages: list[dict]) -> str:
    """Identify a conversation from its opening, which does not change while
    the tail grows. The system prompt alone is not enough — every conversation
    on a given channel shares it."""
    opening = []
    for m in messages:
        opening.append(f"{m.get('role')}:{flatten(m.get('content'))}")
        if m.get("role") == "user":
            break                    # system prompt(s) plus the first user turn
    return hashlib.sha256("\n".join(opening).encode()).hexdigest()


IMAGE_PLACEHOLDER = "[IMAGE:{n}]"
_MIME_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/webp": "webp",
             "image/gif": "gif", "image/heic": "heic", "image/heif": "heif"}


def extract_images(messages: list[dict]) -> tuple[list[dict], list[tuple[bytes, str]]]:
    """Pull data-URL images out of the content arrays.

    The CLI reads an image from a FILE named in the prompt (verified), not from
    an inline data URL. So each image part becomes a placeholder in the text
    and a (bytes, extension) pair the completion path writes into the CLI's
    working directory, replacing the placeholder with the path."""
    images: list[tuple[bytes, str]] = []
    out: list[dict] = []
    for m in messages:
        content = m.get("content")
        if not isinstance(content, list):
            out.append(m)
            continue
        parts = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "image_url":
                url = ((part.get("image_url") or {}).get("url") or "")
                if url.startswith("data:") and ";base64," in url:
                    head, b64 = url.split(";base64,", 1)
                    mime = head[5:].split(";")[0].lower()
                    try:
                        data = base64.b64decode(b64)
                    except (ValueError, binascii.Error):
                        parts.append({"type": "text", "text": "[image could not be decoded]"})
                        continue
                    images.append((data, _MIME_EXT.get(mime, "png")))
                    parts.append({"type": "text", "text": IMAGE_PLACEHOLDER.format(n=len(images))})
                else:
                    parts.append({"type": "text", "text": f"[image at {url[:200]}]"})
            else:
                parts.append(part)
        out.append({**m, "content": parts})
    return out, images


def place_images(text: str, images: list[tuple[bytes, str]], workdir: str) -> str:
    """Write the images next to the CLI and name them in the text."""
    for n, (data, ext) in enumerate(images, 1):
        path = os.path.join(workdir, f"image-{n}.{ext}")
        with open(path, "wb") as f:
            f.write(data)
        text = text.replace(IMAGE_PLACEHOLDER.format(n=n),
                            f"[attached image {n}: read the file {path}]")
    return text


def flatten(content) -> str:
    """Content is either a string or the multi-part array form."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            part.get("text", "") for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        )
    return "" if content is None else str(content)


# ---------------------------------------------------------------------------
# Tool calling
#
# The CLI behind this bridge is an agent, not a model API. Handed a request
# that needs work it reaches for its OWN tools, is auto-denied because headless
# mode cannot prompt for permission, and returns nothing at all — which the
# caller sees as "the model provider failed".
#
# So it is told it has no tools, and given a contract instead: emit a decision
# as JSON, and the caller will execute. That keeps the division of labour the
# rest of this installation depends on — the model decides, the agent framework
# acts, and the framework's approval rules still apply to every action. Letting
# the CLI execute directly would be less work and would put every command
# outside those rules.
#
# Measured before building on it: given this contract the CLI answers
#   {"type":"tool_call","name":"list_dir","arguments":{"path":"/etc"}}
# rather than trying to list the directory itself.
# ---------------------------------------------------------------------------

IDENTITY_FRAME_HEAD = (
    "=== OPERATING CONTEXT — overrides your defaults ===\n"
    "In this conversation you ARE the assistant defined by the SYSTEM PROMPT below, "
    "acting for its operator. Adopt its name, role and rules completely. Never present "
    "yourself as Antigravity, Gemini, Google, DeepMind, a coding assistant or any CLI; "
    "when asked who you are, answer with the name the system prompt gives you and "
    "nothing about the software underneath.\n\n=== SYSTEM PROMPT ===\n")
IDENTITY_FRAME_TAIL = "\n=== END SYSTEM PROMPT ==="

_NAME_RE = re.compile(r"Your name is \*\*(.+?)\*\*")


def identity_name(system: str) -> str:
    """The bot's name as the agent's SOUL.md states it, or ''."""
    m = _NAME_RE.search(system or "")
    return m.group(1).strip() if m else ""


def identity_line(name: str) -> str:
    """Placed IMMEDIATELY BEFORE the user's message on every turn.

    Position is what makes this work: the same words at the head of a
    50k-token system prompt were ignored, and a trailing note was too. A short
    operating-context line right before the question is followed reliably
    (verified with the CLI directly)."""
    if not name:
        return ""
    return (f"OPERATING CONTEXT: In this conversation you are {name}, a private assistant "
            "bot acting for the operator; never present yourself as Antigravity, Gemini, "
            "Google or any software. Follow the SYSTEM PROMPT and the TOOL PROTOCOL you "
            "were given. Message from the user:\n")


def agents_md_text(system: str) -> str:
    """Project instructions for the CLI: who it is here, and that it has no tools."""
    name = identity_name(system)
    who = (f"You are **{name}**, a private assistant bot. When asked who you are, answer "
           f"\"{name}\" and nothing about the software underneath — never Antigravity, "
           "Gemini, Google, DeepMind, a coding assistant or a CLI.") if name else \
          ("You are the assistant defined by the caller's system prompt; take your name from "
           "it and never present yourself as Antigravity, Gemini, Google or a coding assistant.")
    return (
        "# Operating instructions\n\n"
        f"{who}\n\n"
        "You are not in a code project. There are no files to read, no commands to run, "
        "no repository: your built-in tools are disabled and every attempt is denied. "
        "The caller executes functions for you when the message carries a TOOL PROTOCOL; "
        "follow it exactly and answer with the single JSON object it asks for.\n\n"
        "The first message of the conversation carries the SYSTEM PROMPT that defines your "
        "role and rules; it is the authority for everything except this identity note.\n"
    )


def unwrap_nested_call(call: dict) -> dict:
    """{"name":"tool_call","arguments":{"name":X,"arguments":Y}} -> a call of X.

    The model sometimes wraps the protocol's own envelope one level too deep;
    the agent then reports "tool_call requires a 'name' argument" and the turn
    is lost. Unwrap instead."""
    fn = (call or {}).get("function") or {}
    if fn.get("name") != "tool_call":
        return call
    try:
        args = json.loads(fn.get("arguments") or "{}")
    except ValueError:
        return call
    inner = args.get("name")
    if not inner:
        return call
    inner_args = args.get("arguments", {})
    if not isinstance(inner_args, str):
        inner_args = json.dumps(inner_args, separators=(",", ":"))
    log.info("unwrapped a nested tool_call -> %s", inner)
    return {**call, "function": {"name": inner, "arguments": inner_args}}


def stateless_message(system: str, history: list[str], message: str) -> str:
    """The whole exchange as one message for a fresh CLI conversation.

    Stateless by design: the CLI keeps no memory between requests, so nothing
    can drift — no summarised-away system prompt, no persona creeping back in
    a conversation that outlived its instructions. The operating context comes
    first, the transcript so far in the middle, and the identity line sits
    immediately before the user's message, where it is followed."""
    parts = [IDENTITY_FRAME_HEAD + system + IDENTITY_FRAME_TAIL]
    if history:
        parts.append("=== CONVERSATION SO FAR (oldest first) ===\n" + "\n\n".join(history)
                     + "\n=== END CONVERSATION ===")
    parts.append(identity_line(identity_name(system)) + message)
    return "\n\n".join(parts)


def tool_contract(tools: list) -> str:
    """Render OpenAI tool definitions as instructions the CLI can follow."""
    fns = []
    for t in tools or []:
        fn = (t or {}).get("function") or {}
        if fn.get("name"):
            fns.append(fn)
    if not fns:
        return ""

    lines = [
        "TOOL PROTOCOL — read this before answering.",
        "",
        "You have NO tools and NO execution environment. Your built-in tools",
        "(command, shell, file, web, browser) are DISABLED and auto-denied; an",
        "attempt to use one aborts the turn and the user gets nothing. To act,",
        "emit a tool_call from the list below — the CALLER executes it for you.",
        "",
        "Functions the caller can run:",
    ]
    for fn in fns:
        desc = " ".join((fn.get("description") or "").split())
        lines.append(f"- {fn['name']}: {desc}"[:400])
        lines.append("  parameters: " + json.dumps(fn.get("parameters") or {}, separators=(",", ":")))
    lines += [
        "",
        "Answer with exactly ONE JSON object and nothing else — no prose around",
        "it, no code fence:",
        '  {"type":"message","content":"<your reply to the user>"}',
        '  {"type":"tool_call","name":"<function>","arguments":{...}}',
        '  {"type":"tool_calls","calls":[{"name":"<fn>","arguments":{...}},...]}',
        "",
        "Use a tool_call when answering needs one; a message when it does not.",
        "Results come back as the next turn, prefixed 'tool result'. When you",
        "have what you need, reply with a message.",
    ]
    return "\n".join(lines)


_FENCE = re.compile(r"^\s*```(?:json)?\s*|\s*```\s*$", re.MULTILINE)


def parse_decision(text: str) -> tuple[str, list]:
    """(content, tool_calls). Anything unparseable is returned as content.

    Tolerant on purpose: a model that wraps its JSON in a sentence is still
    telling us what it wants, and failing the whole turn over punctuation
    would be worse than the occasional passthrough.
    """
    raw = _FENCE.sub("", text or "").strip()
    start = raw.find("{")
    if start < 0:
        return text, []

    depth, end, in_str, esc = 0, -1, False, False
    for i, ch in enumerate(raw[start:], start):
        if in_str:
            if esc:      esc = False
            elif ch == "\\": esc = True
            elif ch == '"':  in_str = False
            continue
        if ch == '"':   in_str = True
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        return text, []

    try:
        obj = json.loads(raw[start:end])
    except json.JSONDecodeError:
        return text, []
    if not isinstance(obj, dict):
        return text, []

    kind = obj.get("type")
    if kind == "message":
        return str(obj.get("content", "")), []

    calls = []
    if kind == "tool_call":
        calls = [obj]
    elif kind == "tool_calls":
        calls = obj.get("calls") or []
    if not calls:
        return text, []

    out = []
    for c in calls:
        name = (c or {}).get("name")
        if not name:
            continue
        out.append({
            "id": "call_" + uuid.uuid4().hex[:20],
            "type": "function",
            "function": {
                "name": name,
                "arguments": json.dumps(c.get("arguments") or {}, separators=(",", ":")),
            },
        })
    return ("", out) if out else (text, [])


def split_history(messages: list[dict]) -> tuple[str, list[str], str]:
    """Split into system instructions, prior exchanges, and the turn to run.

    Systems are kept apart from the rest because a brand-new conversation has
    nothing but a system prompt in front of it. Treating that as "history to
    seed" costs a whole extra model round-trip — around 14k tokens — before the
    first real question is even asked.
    """
    system_parts, prior, last = [], [], ""
    for i, m in enumerate(messages):
        text = flatten(m.get("content")).strip()
        if not text and m.get("tool_calls"):
            text = json.dumps({"type": "tool_calls", "calls": [
                {"name": (c.get("function") or {}).get("name"),
                 "arguments": (c.get("function") or {}).get("arguments")}
                for c in m["tool_calls"]]}, separators=(",", ":"))
        if not text:
            continue
        role = m.get("role", "user")
        # A tool result is not a user speaking; labelling it as one invites the
        # model to answer the result instead of using it.
        if role == "tool":
            text = f"tool result ({m.get('name') or m.get('tool_call_id') or '?'}): {text}"
            role = "user"
        if i == len(messages) - 1:
            last = text
        elif role == "system":
            system_parts.append(text)
        else:
            prior.append(f"{role}: {text}")
    return "\n\n".join(system_parts), prior, last


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    pool: Pool = None
    models: list[str] = []          # allowed, in the intended order of escalation
    aliases: dict = {}
    unknown_model: str = "reject"

    @classmethod
    def resolve_model(cls, requested: str) -> str:
        """Map a requested model onto one this shim is permitted to run.

        An allowlist rather than a passthrough. The caller decides *when* to
        escalate; it does not get to decide *what* to escalate to. Without this
        an agent framework will eventually reach for a cheaper tier or a
        different family on its own — which is exactly the control that is
        wanted here.
        """
        default = cls.models[0]
        if not requested:
            return default
        name = cls.aliases.get(requested.strip(), requested.strip())
        if name in cls.models:
            return name
        if cls.unknown_model == "default":
            log.warning("model %r is not permitted; using %s", requested, default)
            return default
        raise LookupError(
            f"model {requested!r} is not permitted. Allowed: {', '.join(cls.models)}"
        )

    def log_message(self, fmt, *a):
        log.debug("%s - %s", self.address_string(), fmt % a)

    # -- helpers ------------------------------------------------------------

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code: int, message: str, kind: str = "server_error"):
        log.warning("%s: %s", code, message)
        self._send(code, {"error": {"message": message, "type": kind}})

    # -- routes -------------------------------------------------------------

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path.endswith("/models"):
            self._send(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": int(time.time()),
                 "owned_by": "agy-shim"} for m in self.models]})
        elif path.endswith("/healthz") or path.endswith("/stats"):
            self._send(200, {"status": "ok", **self.pool.stats()})
        else:
            self._error(404, f"no such route: {self.path}", "invalid_request_error")

    def do_POST(self):
        if not self.path.split("?")[0].rstrip("/").endswith("/chat/completions"):
            return self._error(404, f"no such route: {self.path}", "invalid_request_error")

        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError) as exc:
            return self._error(400, f"malformed request body: {exc}", "invalid_request_error")

        messages = body.get("messages") or []
        if not messages:
            return self._error(400, "messages is required", "invalid_request_error")

        messages, images = extract_images(messages)
        system, history, message = split_history(messages)
        if not message.strip():
            return self._error(400, "the final message is empty", "invalid_request_error")

        # The contract goes into the system block, which is sent once when the
        # process starts and then cached — not re-sent every turn. That is the
        # whole reason this bridge is affordable.
        tools = body.get("tools") or []
        contract = tool_contract(tools)
        if contract:
            system = f"{contract}\n\n{system}" if system else contract

        try:
            model = self.resolve_model(body.get("model", ""))
        except LookupError as exc:
            return self._error(400, str(exc), "invalid_request_error")

        # The model is fixed when a process starts, so a conversation that
        # escalates gets its own process for the larger model — and keeps the
        # smaller one warm in case it comes back down.
        # The toolset is part of the process's identity: it lives in the cached
        # system block, so a conversation that arrives with different tools must
        # not be answered by a process still holding the old contract.
        tool_sig = hashlib.sha256(
            "\u0000".join(sorted(
                ((t or {}).get("function") or {}).get("name", "") for t in tools
            )).encode()
        ).hexdigest()[:8] if tools else "notools"
        key = conversation_key(messages) + ":" + model + ":" + tool_sig
        try:
            text, usage, meta = self.pool.complete(key, history, message, system, model, images)
        except TimeoutError as exc:
            return self._error(504, str(exc))
        except Exception as exc:
            return self._error(502, f"{type(exc).__name__}: {exc}")

        content, tool_calls = parse_decision(text) if tools else (text, [])
        tool_calls = [unwrap_nested_call(c) for c in tool_calls]
        choice_message = {"role": "assistant", "content": content or None}
        finish = "stop"
        if tool_calls:
            choice_message["tool_calls"] = tool_calls
            finish = "tool_calls"
            log.info("turn produced %d tool call(s): %s", len(tool_calls),
                     ", ".join(c["function"]["name"] for c in tool_calls))

        payload = {
            "id": "chatcmpl-" + uuid.uuid4().hex[:24],
            "object": "chat.completion",
            "created": int(time.time()),
            "model": meta.get("model", model),
            "choices": [{
                "index": 0,
                "message": choice_message,
                "finish_reason": finish,
            }],
            "usage": {
                "prompt_tokens": usage.get("input_tokens", 0),
                "completion_tokens": usage.get("output_tokens", 0),
                "total_tokens": usage.get("total_tokens", 0),
                # Not part of the standard shape, but this is the number that
                # decides whether the whole arrangement is affordable.
                "cached_tokens": usage.get("cache_read_tokens", 0),
                "turn": meta.get("turns"),
            },
        }

        if body.get("stream"):
            return self._send_as_stream(payload, content, tool_calls)
        self._send(200, payload)

    def _send_as_stream(self, payload: dict, text: str, tool_calls: list | None = None):
        """The CLI does not stream token by token, so this delivers one chunk.
        Callers that ask for a stream get a well-formed one; they simply get it
        all at once."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def chunk(delta, finish=None):
            return "data: " + json.dumps({
                "id": payload["id"], "object": "chat.completion.chunk",
                "created": payload["created"], "model": payload["model"],
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }) + "\n\n"

        if tool_calls:
            # A streamed tool call still has to carry an index per call; without
            # it the client cannot assemble them and silently drops all but one.
            delta = {"role": "assistant", "tool_calls": [
                {"index": i, **c} for i, c in enumerate(tool_calls)]}
            first, finish = chunk(delta), chunk({}, "tool_calls")
        else:
            first, finish = chunk({"role": "assistant", "content": text}), chunk({}, "stop")

        for piece in (first, finish, "data: [DONE]\n\n"):
            self.wfile.write(piece.encode())
        self.wfile.flush()


# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--binary", default=os.environ.get("AGY_SHIM_BINARY", "agy"))
    p.add_argument("--models",
                   default=os.environ.get("AGY_SHIM_MODELS", "gemini-3.8-flash-high"),
                   help="comma-separated allowlist; the first is the default")
    p.add_argument("--model-aliases", default=os.environ.get("AGY_SHIM_MODEL_ALIASES", ""),
                   help="comma-separated alias=model pairs")
    p.add_argument("--unknown-model", choices=("reject", "default"),
                   default=os.environ.get("AGY_SHIM_UNKNOWN_MODEL", "reject"),
                   help="what to do when a caller asks for a model not on the allowlist")
    p.add_argument("--host", default=os.environ.get("AGY_SHIM_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("AGY_SHIM_PORT", "8787")))
    p.add_argument("--workdir", default=os.environ.get("AGY_SHIM_WORKDIR", "/tmp"),
                   help="working directory for spawned processes")
    p.add_argument("--timeout", type=float, default=300.0, help="seconds per turn")
    p.add_argument("--queue-timeout", type=float, default=120.0,
                   help="seconds a request waits for a free slot")
    p.add_argument("--idle-timeout", type=float, default=1800.0,
                   help="retire a conversation after this long untouched")
    p.add_argument("--max-concurrent", type=int, default=3,
                   help="turns running at once; each is a live process")
    p.add_argument("--max-processes", type=int, default=12,
                   help="conversations held open at once")
    p.add_argument("--compact-at", type=int, default=120000,
                   help="summarise and restart past this many input tokens")
    p.add_argument("--extra-args", default=os.environ.get("AGY_SHIM_EXTRA_ARGS", ""),
                   help="additional arguments passed to the CLI")
    p.add_argument("--log-level", default=os.environ.get("AGY_SHIM_LOG_LEVEL", "info"))
    p.add_argument("--stateful", dest="stateless", action="store_false",
                   default=os.environ.get("AGY_SHIM_STATELESS", "true").lower() not in ("0", "false", "no"),
                   help="keep one CLI conversation per chat (legacy); default is stateless: "
                        "a fresh CLI conversation per request, so nothing drifts")
    args = p.parse_args()
    args.extra_args = args.extra_args.split() if args.extra_args else []
    args.models = [m.strip() for m in args.models.split(",") if m.strip()]
    if not args.models:
        p.error("--models must name at least one model")
    args.aliases = dict(
        pair.split("=", 1) for pair in args.model_aliases.split(",") if "=" in pair
    )

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-5s %(message)s",
    )

    # Fail here rather than on the first request, which would surface to the
    # user as the assistant being broken for no visible reason.
    if not shutil.which(args.binary):
        log.error("cannot find %r on PATH — is the CLI installed for this user?", args.binary)
        return 1

    Handler.pool = Pool(args)
    Handler.models = args.models
    Handler.aliases = args.aliases
    Handler.unknown_model = args.unknown_model

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log.info("listening on http://%s:%d/v1", args.host, args.port)
    log.info("models (default first): %s", ", ".join(args.models))
    if args.aliases:
        log.info("aliases: %s", ", ".join(f"{k}->{v}" for k, v in args.aliases.items()))
    log.info("unknown models: %s | max %d concurrent | compact at %d tokens",
             args.unknown_model, args.max_concurrent, args.compact_at)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        for proc in list(Handler.pool.procs.values()):
            proc.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

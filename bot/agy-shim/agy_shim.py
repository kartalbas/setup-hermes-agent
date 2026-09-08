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
import shlex
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

# The CLI's own wait ceiling; kept above the bridge's per-turn timeout so a
# slow turn is reported by us (with context), not cut by the CLI (without).
PRINT_TIMEOUT_SECONDS = 900

# How long a turn may still run once the decision is in: the model was told to
# end it, and what it writes after that is discarded — but the result event it
# ends with carries the token counts, so it is worth a short wait.
DECISION_GRACE_SECONDS = 45

# The caller's tools, offered to the CLI as a real MCP server so the model calls
# them natively (ADR 0024). The server is tools_mcp.py next to this file; it
# reads TOOLS_FILE from the CLI's working directory — the per-conversation
# directory this bridge creates — so one global server entry serves every bot.
TOOLS_SERVER_NAME = "tools"
TOOLS_FILE = "tools.json"
TOOLS_SERVER_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools_mcp.py")


class TransientTurnError(RuntimeError):
    """A failure the CLI is known to produce spuriously — one fresh retry is due."""


# ---------------------------------------------------------------------------
# One conversation, one CLI process
# ---------------------------------------------------------------------------

class AgentProcess:
    """A living CLI process holding one conversation.

    Output is drained by a reader thread. Without that, a process writing more
    than a pipe buffer while nobody reads it deadlocks — and the failure looks
    like the model being slow rather than like a bug here.
    """

    def __init__(self, binary: str, model: str, workdir: str, extra_args: list[str], agents_md: str = "",
                 agent_def: str = "", tools_spec: list | None = None):
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
        # The caller's functions for the tools server the CLI spawns. The CLI
        # asks that server for its list once, at start — so the file is there
        # before the spawn, and a process's toolset is fixed for its life.
        self.tools_spec = tools_spec
        self.agents_md = agents_md
        self.agent_def = agent_def
        if tools_spec:
            write_tools_file(self.workdir, tools_spec)
        # The agent definition: the caller's system prompt in the CLI's own
        # system-prompt slot, its built-in tools switched off (see agent_file_text).
        self.agent_mode = bool(agent_def)
        if agent_def:
            adir = os.path.join(self.workdir, ".agents", "agents")
            os.makedirs(adir, exist_ok=True)
            with open(os.path.join(adir, f"{AGENT_NAME}.md"), "w", encoding="utf-8") as f:
                f.write(agent_def)
        self.created = time.time()
        self.last_used = self.created
        self.turns = 0
        self.input_tokens = 0        # from the most recent turn, not a sum:
                                     # the CLI reports cumulative context size
        self.lock = threading.Lock()
        self._closed = False

        # --disable-slash-commands: a chat message starting with "/" (Teams
        # "/help") would otherwise be expanded as a CLI command and burn a
        # turn. --print-timeout: the CLI's own ceiling, kept above ours so it
        # never fires first and masks the real cause.
        cmd = [binary, "--input-format", "stream-json", "--output-format", "stream-json",
               "--model", model, "--disable-slash-commands",
               "--print-timeout", f"{int(PRINT_TIMEOUT_SECONDS)}s"]
        if self.agent_mode:
            cmd += ["--agent", AGENT_NAME, "--add-dir", self.workdir]
        cmd += extra_args
        log.debug("spawning: %s", " ".join(cmd))

        self.proc = subprocess.Popen(
            cmd, cwd=self.workdir,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
            # A clean environment except for what the CLI needs to find its own
            # credentials. HOME is what decides which account it runs as.
            # A clean environment except for what the CLI needs to find its own
            # credentials (HOME decides the account) and its own switches
            # (AGY_CLI_*: auto-update off, account info hidden).
            env={k: v for k, v in os.environ.items()
                 if k in ("HOME", "PATH", "USER", "LOGNAME", "LANG", "TERM") or k.startswith("AGY_CLI_")},
        )

        self._events: queue.Queue = queue.Queue()
        self._stderr_tail: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        self.conversation_id = None
        self.tool_count = None
        self.pending_prefix = ""
        self.tool_intents: list[dict] = []
        self.available_tools: set[str] = set()
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
                # A settings.json that switches the CLI to always-proceed would
                # let it run commands on this host. Refuse to serve on that.
                mode = init.get("permission_mode")
                if mode and mode not in ("request-review", "request_review"):
                    raise RuntimeError(f"CLI permission mode is {mode!r}; the bridge serves only request-review")
                log.info("started conversation %s (model=%s, %s tools)",
                         (self.conversation_id or "?")[:8], init.get("model"), self.tool_count)
                return
        raise RuntimeError(f"no init event within {timeout}s: {self.stderr_tail()}")

    def stderr_tail(self) -> str:
        return " | ".join(self._stderr_tail[-3:]) or "(no stderr)"

    def alive(self) -> bool:
        return not self._closed and self.proc.poll() is None

    # -- the actual work ----------------------------------------------------

    _denied_shape_logged = False

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

        self.tool_intents = []
        self.native_decision = None
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
                if self.native_decision is not None:
                    # The decision is complete; only the model's closing line is
                    # missing, and it is discarded anyway.
                    log.info("decision taken, closing line not written within %.0fs; going with it", DECISION_GRACE_SECONDS)
                    self.turns += 1
                    self.last_used = time.time()
                    return {"status": "SUCCESS", "response": json.dumps(self.native_decision, separators=(",", ":")),
                            "usage": {}, "native_call": True}
                raise TimeoutError(f"no result within {timeout}s")
            try:
                ev = self._events.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError(f"no result within {timeout}s")
            if ev is None:
                raise RuntimeError(f"process exited mid-turn: {self.stderr_tail()}")
            if ev.get("event") == "step_update":
                su = ev.get("step_update") or {}
                if su.get("step_type") == "tool" and su.get("state") == "ACTIVE":
                    self.tool_intents.append(su.get("tool_info") or {"name": su.get("tool_name"), "parameters": {}})
                broken = native_call_decision(su, getattr(self, "available_tools", set()))
                if broken is not None:
                    # The wrong channel: the CLI rejected the call and the turn
                    # is already lost. Nothing worth waiting for — and on a
                    # one-shot process, waiting only invites a second, malformed
                    # attempt.
                    log.info("native call to the caller's %s taken as the decision", broken["name"])
                    if self.native_decision is None:
                        self.native_decision = broken
                    if getattr(self, "one_shot", False):
                        self.turns += 1
                        self.last_used = time.time()
                        return {"status": "SUCCESS", "response": json.dumps(broken, separators=(",", ":")),
                                "usage": {}, "native_call": True}
                    continue
                offered = mcp_call_decision(su)
                if offered is not None and self.native_decision is None:
                    # The channel this bridge offers: the model called a tool of
                    # ours and was told to end its turn. Its closing line is
                    # discarded, but the turn is allowed to finish — that is
                    # where the token counts live, and they are the whole
                    # measure of whether this arrangement is affordable.
                    log.info("call through the tools server to %s taken as the decision", offered["name"])
                    self.native_decision = offered
                    deadline = min(deadline, time.time() + DECISION_GRACE_SECONDS)
                continue
            if ev.get("event") != "result":
                continue

            result = ev.get("result", {})
            usage = result.get("usage", {}) or {}
            self.turns += 1
            self.last_used = time.time()
            self.input_tokens = usage.get("input_tokens", 0) or 0

            if self.native_decision is not None:
                # A complete native call to a caller function decided the turn:
                # whatever followed — a malformed retry that killed the turn, or
                # the "pending" line the tools server asked for — is not the answer.
                result = dict(result, status="SUCCESS", response=json.dumps(self.native_decision, separators=(",", ":")))
            if result.get("status") != "SUCCESS":
                # CANCELED/WAITING without a client cancel are the CLI's own
                # hiccups (its issues #902/#944): worth exactly one fresh try.
                err = str(result.get("error") or "")
                if result.get("status") in ("CANCELED", "WAITING") or "improperly formatted function call" in err:
                    raise TransientTurnError(f"CLI status {result.get('status')}: {result.get('error') or self.stderr_tail()}")
                raise RuntimeError(result.get("error") or self.stderr_tail())

            # A denied tool permission is reported as success with no text: the
            # CLI abandons the turn rather than answering with what it has. That
            # surfaced as an unexplained failure, so say what actually happened.
            if not str(result.get("response", "")).strip():
                detail = self.stderr_tail()
                denied = result.get("denied_actions") or []
                if denied and not AgentProcess._denied_shape_logged:
                    AgentProcess._denied_shape_logged = True
                    log.info("denied_actions shape: %s", json.dumps(denied)[:400])
                if denied or "permission" in detail.lower():
                    decision = map_cli_intents(self.tool_intents, getattr(self, "available_tools", set()))
                    if decision is not None:
                        result["response"] = json.dumps(decision, separators=(",", ":"))
                        return result
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
                if "authentication timed out" in detail.lower():
                    raise TransientTurnError("CLI authentication timed out. " + detail)
                raise TransientTurnError("the model returned an empty response. " + detail)
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
            # The CLI has been seen to linger after SIGTERM (its issue #947);
            # a hard kill and a bounded wait keep the pool from filling up.
            try:
                self.proc.kill()
                self.proc.wait(timeout=5)
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


def sweep_stale_workdirs(root: str, max_age_s: float = 3600.0) -> int:
    """Remove `agy-shim-*` directories under ROOT older than MAX_AGE_S — what a
    killed bridge or an older version left behind (37 of them on one host)."""
    removed = 0
    try:
        names = os.listdir(root)
    except OSError:
        return 0
    now = time.time()
    for name in names:
        if not name.startswith("agy-shim-"):
            continue
        path = os.path.join(root, name)
        try:
            if os.path.isdir(path) and now - os.path.getmtime(path) > max_age_s:
                shutil.rmtree(path, ignore_errors=True)
                removed += 1
        except OSError:
            continue
    return removed


class Pool:
    def __init__(self, args):
        swept = sweep_stale_workdirs(args.workdir or tempfile.gettempdir())
        if swept:
            log.info("removed %d stale working directories of earlier bridge processes", swept)
        self.args = args
        # Whether the CLI will inject the caller's functions as real tools: it
        # does when its own configuration names our tools server (the installer
        # writes that). Checked once, here, so a turn never has to guess.
        self.native_tools = tools_server_configured() if getattr(args, "native_tools", "auto") == "auto" \
            else bool(getattr(args, "native_tools", "auto") == "on")
        log.info("caller tools reach the model %s", "as native MCP tools" if self.native_tools
                 else "as the text TOOL PROTOCOL (no tools server in the CLI's configuration)")
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
                      model: str, tools: list | None = None) -> AgentProcess:
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
                                agents_md=agents_md_text(system),
                                agent_def=agent_file_text(system) if self.args.agent_mode else "",
                                tools_spec=tools if self.native_tools else None)
            self.procs[key] = proc

        # In agent mode the system prompt is already in the CLI's own system
        # slot (the agent definition), so the conversation must not carry it a
        # second time: seeding replays the transcript alone, and there is no
        # prefix to prepend to the first message.
        carried = "" if self.args.agent_mode else system
        # Seeding costs a model round-trip, so it happens only when there is
        # genuine prior conversation to replay — and outside the pool lock,
        # which would otherwise block every other conversation meanwhile.
        proc.identity = identity_name(system)
        if seed:
            with proc.lock:
                proc.turn(self._seed_message(seed, carried), self.args.timeout)
            log.info("seeded conversation %s with %d prior messages", key[:8], len(seed))
        elif carried:
            # Nothing to replay: the system prompt rides along with the first
            # real message instead of burning a turn of its own.
            # The CLI has an identity of its own and answers "who are you" with
            # it unless told, in the conversation, that here it acts as someone
            # else. The frame makes the agent's system prompt (which carries the
            # bot's name from SOUL.md) the authority on that.
            proc.pending_prefix = IDENTITY_FRAME_HEAD + carried + IDENTITY_FRAME_TAIL
            proc.full_prefix = proc.pending_prefix       # kept for the reminder
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
                                 self.args.workdir, self.args.extra_args,
                                 agents_md=proc.agents_md, agent_def=proc.agent_def,
                                 tools_spec=proc.tools_spec)
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
                            images: list[tuple[bytes, str]],
                            tool_names: set[str],
                            tools: list | None = None) -> tuple[str, dict, dict]:
        spec = tools if self.native_tools else None
        # A pre-warmed spare cannot serve a request whose system prompt or
        # toolset it does not carry: both are read at spawn (the agent
        # definition, and the tools file the CLI's tools server lists once).
        if self.args.agent_mode or spec:
            proc = AgentProcess(self.args.binary, model, self.args.workdir, self.args.extra_args,
                                agents_md="" if self.args.agent_mode else agents_md_text(system),
                                agent_def=agent_file_text(system) if self.args.agent_mode else "",
                                tools_spec=spec)
        else:
            proc = self._take_spare(model)
        proc.available_tools = tool_names
        try:
            text = (transcript_message(history, message, identity_name(system)) if self.args.agent_mode
                    else stateless_message(system, history, message))
            if images:
                text = place_images(text, images, proc.workdir)
            proc.full_prefix = text          # re-sent whole if a built-in tool is denied
            proc.identity = identity_name(system)
            proc.one_shot = True
            started = time.time()
            try:
                with proc.lock:
                    result = proc.turn(text, self.args.timeout)
            except TransientTurnError as exc:
                # Once, on a fresh process: the CLI's spurious empty/canceled
                # turns clear on retry; a genuine failure costs one extra turn.
                log.warning("transient CLI failure (%s); retrying once on a fresh process", str(exc)[:160])
                threading.Thread(target=proc.close, daemon=True).start()
                proc = (AgentProcess(self.args.binary, model, self.args.workdir, self.args.extra_args,
                                     agents_md="" if self.args.agent_mode else agents_md_text(system),
                                     agent_def=agent_file_text(system) if self.args.agent_mode else "",
                                     tools_spec=spec)
                        if (self.args.agent_mode or spec) else self._take_spare(model))
                proc.available_tools = tool_names
                proc.full_prefix = text
                proc.identity = identity_name(system)
                proc.one_shot = True
                reminder = (MCP_CALL_REMINDER if spec else NATIVE_CALL_REMINDER) if tool_names else ""
                with proc.lock:
                    result = proc.turn(text + reminder, self.args.timeout)
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
                 images: list[tuple[bytes, str]] | None = None,
                 tool_names: set[str] | None = None,
                 tools: list | None = None) -> tuple[str, dict, dict]:
        acquired = self.slots.acquire(timeout=self.args.queue_timeout)
        if not acquired:
            raise TimeoutError("too many conversations in flight")
        try:
            if self.args.stateless:
                return self._complete_stateless(history, message, system, model, images or [], tool_names or set(), tools)
            proc = self._get_or_start(key, history, system, model, tools)
            proc.available_tools = tool_names or set()

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
                "mode": ("stateless" if self.args.stateless else "stateful") + ("+agent" if self.args.agent_mode else "")
                        + ("+native-tools" if self.native_tools else ""),
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
            "Google or any software. Follow the SYSTEM PROMPT and the tool instructions you "
            "were given. Message from the user:\n")


AGENT_NAME = "hermes"


def agent_file_text(system: str) -> str:
    """The CLI agent definition that carries the caller's system prompt.

    `--agent <name>` loads `.agents/agents/<name>.md` from the workspace and
    compiles its body into the CLI's system prompt — the slot our text never
    reached from a user message. `tools: []` and `commandExecutionPolicy: off`
    remove the CLI's own tools, so nothing is left to reach for; the caller's
    functions arrive through the TOOL PROTOCOL inside the body. Verified
    2026-09-07: identity replaced, no tool intents, prompt 5.3k -> 2.3k tokens."""
    body = IDENTITY_FRAME_HEAD + system + IDENTITY_FRAME_TAIL
    return ("---\n"
            f"name: {AGENT_NAME}\n"
            "description: The caller's assistant, defined entirely by the system prompt below\n"
            "tools: []\n"
            "commandExecutionPolicy: off\n"
            "inheritCustomizations: false\n"
            "subagent: false\n"
            "---\n" + body + "\n")


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
        f"The caller executes functions for you: the tools of the `{TOOLS_SERVER_NAME}` server, called natively, "
        "or — when the message carries a TOOL PROTOCOL instead — the single JSON object it asks for.\n\n"
        "The first message of the conversation carries the SYSTEM PROMPT that defines your "
        "role and rules; it is the authority for everything except this identity note.\n"
    )


def native_call_decision(step_update: dict, available: set) -> dict | None:
    """A CLI tool step that failed as 'unknown tool' for a name the CALLER
    offers is the model calling the caller's function natively — complete
    arguments, wrong channel. Returned as the decision the caller expects.

    Why it matters: the CLI keeps at least one built-in function declared
    whatever the agent definition says (manage_task), so the model can always
    emit native function calls, and does so for the caller's names. A parseable
    one becomes this 'unknown tool' step; an unparseable one is what the API
    rejects as a malformed function call — the CLI retries that three times and
    then fails the turn (seen 2026-09-07, six turns in a row on a long GitHub
    transcript). Taking the parseable call ends the turn before the model gets
    a second, riskier attempt."""
    su = step_update or {}
    if su.get("step_type") != "tool" or su.get("state") != "ERROR":
        return None
    err = su.get("error")
    msg = str((err.get("message") if isinstance(err, dict) else err) or "")
    if "unknown tool" not in msg.lower():
        return None
    info = su.get("tool_info") or {}
    name = info.get("name") or su.get("tool_name")
    if not name or name not in (available or set()):
        return None
    args = info.get("parameters")
    return {"type": "tool_call", "name": name, "arguments": args if isinstance(args, dict) else {}}


def mcp_call_decision(step_update: dict) -> dict | None:
    """A CLI `call_mcp_tool` step aimed at the caller's tools server is the
    model calling the caller's function natively — the channel this bridge
    offers on purpose (ADR 0024). Taken when the step is DONE: the server has
    validated the arguments by then (a first attempt with missing ones comes
    back as an error the model corrects within the turn, seen 3 of 4 times).
    A call the CLI DENIED for want of the allow rule is taken too when it
    carries arguments — the installer writes the rule; until then this keeps
    the turn alive and says what is missing."""
    su = step_update or {}
    if su.get("step_type") != "tool":
        return None
    info = su.get("tool_info") or {}
    if (info.get("name") or su.get("tool_name")) != "call_mcp_tool":
        return None
    params = info.get("parameters") or {}
    if params.get("ServerName") != TOOLS_SERVER_NAME or not params.get("ToolName"):
        return None
    args = params.get("Arguments")
    args = args if isinstance(args, dict) else {}
    decision = {"type": "tool_call", "name": str(params["ToolName"]), "arguments": args}
    state = su.get("state")
    if state == "DONE":
        return decision
    if state == "ERROR" and args:
        err = su.get("error") or info.get("error") or ""
        msg = str((err.get("message") if isinstance(err, dict) else err) or "")
        if "denied" in msg.lower():
            log.warning("the CLI denied the call to the tools server: permissions.allow lacks mcp(%s/*) — the installer writes it", TOOLS_SERVER_NAME)
            return decision
    return None


def cli_config_paths() -> tuple[str, str]:
    """Where the CLI keeps the two files this bridge depends on: the MCP
    server registry, and the settings that permit calling those servers."""
    home = os.path.expanduser("~")
    return (os.path.join(home, ".gemini", "config", "mcp_config.json"),
            os.path.join(home, ".gemini", "antigravity-cli", "settings.json"))


def tools_server_configured() -> bool:
    """Does the CLI know our tools server, and may it call it?

    Both are the installer's doing (libs/35-agy-shim.sh). Without the server
    entry the model has no functions and the text protocol is the only
    channel; without the allow rule every call is auto-denied in headless mode
    (the bridge still salvages the arguments, but the model pays a turn for
    it), so that case is a warning, not a refusal."""
    mcp_path, settings_path = cli_config_paths()
    try:
        with open(mcp_path, encoding="utf-8") as f:
            servers = (json.load(f) or {}).get("mcpServers") or {}
    except (OSError, ValueError):
        return False
    entry = servers.get(TOOLS_SERVER_NAME)
    if not isinstance(entry, dict) or entry.get("disabled") is True:
        return False
    try:
        with open(settings_path, encoding="utf-8") as f:
            allow = ((json.load(f) or {}).get("permissions") or {}).get("allow") or []
    except (OSError, ValueError):
        allow = []
    if not any(str(r).startswith(f"mcp({TOOLS_SERVER_NAME}") for r in allow):
        log.warning("the CLI knows the tools server but %s has no mcp(%s/*) allow rule: "
                    "every call will be auto-denied and cost a turn — run the installer's agyshim module",
                    settings_path, TOOLS_SERVER_NAME)
    return True


def tool_functions(tools: list) -> list[dict]:
    """The function specs (name, description, parameters) out of OpenAI tool
    definitions, in the caller's order; entries without a name are dropped."""
    out = []
    for t in tools or []:
        fn = (t or {}).get("function") or {}
        if fn.get("name"):
            out.append({"name": fn["name"], "description": fn.get("description") or "", "parameters": fn.get("parameters") or {}})
    return out


def tools_signature(tools: list) -> str:
    """What identifies a toolset for a process: the sorted names."""
    names = sorted(fn["name"] for fn in tool_functions(tools))
    return hashlib.sha256(" ".join(names).encode()).hexdigest()[:8] if names else "notools"


def write_tools_file(workdir: str, tools: list) -> str:
    """tools.json in the CLI's working directory, for the tools server."""
    path = os.path.join(workdir, TOOLS_FILE)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(tool_functions(tools), f, ensure_ascii=False)
    return path


NATIVE_CALL_REMINDER = ("\n\nREMINDER: you have no functions to call natively — a native call fails the turn. "
                        "Write the ONE JSON object of the TOOL PROTOCOL as plain text.")
MCP_CALL_REMINDER = (f"\n\nREMINDER: the caller's functions are the tools of the `{TOOLS_SERVER_NAME}` server and nothing else. "
                     "Call ONE of them, with every required argument, or answer in plain prose. Any other function call fails the turn.")


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


# The CLI's own tools, mapped onto the agent's. When the CLI reaches for one of
# them it is denied (headless), but the event stream carries WHAT it wanted —
# `run_command gh repo list`, `view_file /path`. Handing that to the caller as
# a tool call lets the agent execute it with its own tools and policies, and
# the turn goes on instead of dying on "no output produced".
CLI_TOOL_MAP = {
    "run_command":   ("terminal",   lambda a: {"command": a.get("CommandLine") or a.get("command", "")}),
    "list_dir":      ("terminal",   lambda a: {"command": "ls -la " + shlex.quote(a.get("DirectoryPath") or ".")}),
    "grep_search":   ("terminal",   lambda a: {"command": "grep -rn " + shlex.quote(a.get("Query", "")) + " " + shlex.quote(a.get("SearchPath") or ".")}),
    "find_by_name":  ("terminal",   lambda a: {"command": "find " + shlex.quote(a.get("SearchDirectory") or ".") + " -name " + shlex.quote(a.get("Pattern") or "*")}),
    "view_file":     ("read_file",  lambda a: {"path": a.get("AbsolutePath") or a.get("FilePath") or a.get("path", "")}),
    "read_file":     ("read_file",  lambda a: {"path": a.get("AbsolutePath") or a.get("FilePath") or a.get("path", "")}),
    "write_to_file": ("write_file", lambda a: {"path": a.get("TargetFile") or a.get("path", ""),
                                               "content": a.get("CodeContent") or a.get("Content") or a.get("content", "")}),
}


def map_cli_intents(intents: list[dict], available: set[str]) -> dict | None:
    """First CLI tool intent that the caller's tools can carry out, as a decision."""
    for it in intents or []:
        name = (it or {}).get("name") or ""
        args = (it or {}).get("parameters") or {}
        target = CLI_TOOL_MAP.get(name)
        if not target or target[0] not in available:
            continue
        mapped = target[1](args)
        if not any(str(v).strip() for v in mapped.values()):
            continue
        log.info("translated CLI intent %s -> %s", name, target[0])
        return {"type": "tool_call", "name": target[0], "arguments": mapped}
    return None


def transcript_message(history: list[str], message: str, name: str) -> str:
    """Agent mode: the system prompt is in the agent definition; the user
    message carries only the transcript and the new message (identity line
    still directly before it — cheap, and it settled the who-are-you case)."""
    parts = []
    if history:
        parts.append("=== CONVERSATION SO FAR (oldest first) ===\n" + "\n\n".join(history)
                     + "\n=== END CONVERSATION ===")
    parts.append(identity_line(name) + message)
    return "\n\n".join(parts)


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


def tool_contract(tools: list, native: bool = False) -> str:
    """Render OpenAI tool definitions as instructions the CLI can follow.

    NATIVE (the tools server is in place): the CLI has injected the functions
    as real tools, so the text only says whose they are and how they are
    used — call natively, one at a time, complete arguments, the result comes
    back as the next message — and names them once for routing; no schemas,
    no JSON envelope. Otherwise the TOOL PROTOCOL: decisions as JSON text."""
    fns = tool_functions(tools)
    if not fns:
        return ""

    if native:
        lines = [
            "TOOLS — read this before answering.",
            "",
            f"The functions of the `{TOOLS_SERVER_NAME}` server are the caller's tools, and the ONLY",
            "tools you have. Call them natively, one at a time, with every required argument",
            "filled in; the caller executes the call and its result arrives as the next message.",
            "Never write a tool call as JSON text. Never try commands, files, the browser or the",
            "web yourself — those are disabled. When no tool is needed, answer in plain prose.",
            "",
            "The caller's functions:",
        ]
        for fn in fns:
            desc = " ".join((fn.get("description") or "").split())
            lines.append(f"- {fn['name']}: {desc}"[:300])
        return "\n".join(lines)

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


_MESSAGE_ENVELOPE = re.compile(r'^\s*\{\s*"type"\s*:\s*"message"\s*,\s*"content"\s*:\s*"(.*)"\s*\}\s*$', re.S)


def _lenient_message(raw: str) -> str | None:
    """A message envelope that is not valid JSON — unescaped quotes inside the
    content, typically — still has a recognisable shape; take its content."""
    m = _MESSAGE_ENVELOPE.match(raw)
    if not m:
        return None
    body = m.group(1)
    for esc, plain in (('\\"', '"'), ("\\n", "\n"), ("\\t", "\t"), ("\\\\", "\\")):
        body = body.replace(esc, plain)
    return body


def parse_decision(text: str) -> tuple[str, list]:
    """(content, tool_calls). Anything unparseable is returned as content.

    Tolerant on purpose: a model that wraps its JSON in a sentence is still
    telling us what it wants, and failing the whole turn over punctuation
    would be worse than the occasional passthrough.

    Every "{" is tried in turn and the first envelope that parses wins: the
    model has been seen to abandon an envelope before its closing brace,
    emit a stray token, and write it again (2026-09-08) — the rewrite is the
    decision. Arguments may arrive as a string, escaped or with the object's
    own quotes unescaped; both are decoded back into the object.
    """
    raw = _FENCE.sub("", text or "").strip()

    def try_parse(start_idx: int) -> int:
        depth, end, in_str, esc = 0, -1, False, False
        for i, ch in enumerate(raw[start_idx:], start_idx):
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
        return end

    def fix_unescaped_arguments(s: str) -> str:
        def repl(m):
            inner = m.group(1)
            try:
                json.loads(inner)
                return '"arguments":' + inner
            except json.JSONDecodeError:
                try:
                    unescaped = inner.replace('\\"', '"')
                    json.loads(unescaped)
                    return '"arguments":' + unescaped
                except json.JSONDecodeError:
                    return m.group(0)
        return re.sub(r'"arguments"\s*:\s*"(\{.*?\})"(?=\s*[,}\]])', repl, s)

    def extract(obj: dict) -> tuple[str, list]:
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
            args = c.get("arguments")
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    pass
            out.append({
                "id": "call_" + uuid.uuid4().hex[:20],
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(args or {}, separators=(",", ":")) if isinstance(args, dict) else (args if isinstance(args, str) else "{}"),
                },
            })
        return ("", out) if out else (text, [])

    search_start = 0
    while True:
        start = raw.find("{", search_start)
        if start < 0:
            break
        end = try_parse(start)
        if end > 0:
            candidate = raw[start:end]
            fixed = fix_unescaped_arguments(candidate)
            try:
                # strict=False: a model writes real newlines inside the string; JSON
                # forbids them, the reader lived with them (a News briefing arrived as
                # its raw envelope, 2026-09-07).
                obj = json.loads(fixed, strict=False)
                if isinstance(obj, dict) and "type" in obj:
                    return extract(obj)
            except json.JSONDecodeError:
                lenient = _lenient_message(candidate)
                if lenient is not None:
                    return lenient, []
        search_start = start + 1

    return text, []


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
        contract = tool_contract(tools, native=self.pool.native_tools)
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
        key = conversation_key(messages) + ":" + model + ":" + tools_signature(tools)
        try:
            tool_names = {fn["name"] for fn in tool_functions(tools)}
            text, usage, meta = self.pool.complete(key, history, message, system, model, images, tool_names, tools)
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

        try:
            for piece in (first, finish, "data: [DONE]\n\n"):
                self.wfile.write(piece.encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # The caller went away while the answer was streaming — a bot
            # restarted by the installer mid-turn. Nothing to do; the CLI
            # process is closed by the pool as usual.
            log.info("client disconnected before the streamed answer was delivered")


# ---------------------------------------------------------------------------

def startup_checks(args) -> None:
    """Log the CLI version and compare the configured models with its catalog.

    A warning, not a refusal: the catalog call needs the network and the
    account, and a bridge that will not start because a listing hiccupped
    would take every bot down for nothing."""
    try:
        v = subprocess.run([args.binary, "--version"], capture_output=True, text=True, timeout=30).stdout.strip()
        log.info("CLI: %s", v or "(no version output)")
    except Exception as exc:  # noqa: BLE001
        log.warning("could not read the CLI version: %s", exc)
    try:
        out = subprocess.run([args.binary, "--output-format", "json", "models"], capture_output=True, text=True, timeout=60).stdout
        data = json.loads(out) if out.strip() else {}
        names = set()
        items = data.get("models") if isinstance(data, dict) else data
        for m in items or []:
            if isinstance(m, dict):
                for k in ("name", "id", "slug"):
                    if m.get(k):
                        names.add(str(m[k]))
            elif isinstance(m, str):
                names.add(m)
        raw = args.models or []
        wanted = [m for m in (raw if isinstance(raw, list) else str(raw).split(",")) if m]
        missing = [m for m in wanted if names and m not in names]
        if missing:
            log.warning("configured models not in the CLI catalog: %s (catalog: %d entries)", ", ".join(missing), len(names))
        else:
            log.info("model catalog: %d entries; configured models present", len(names))
    except Exception as exc:  # noqa: BLE001
        log.warning("could not read the CLI model catalog: %s", exc)


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
    p.add_argument("--no-agent-mode", dest="agent_mode", action="store_false",
                   default=os.environ.get("AGY_SHIM_AGENT_MODE", "true").lower() not in ("0", "false", "no"),
                   help="do not load the system prompt through a CLI agent definition (--agent); "
                        "default on: the prompt goes into the CLI's system slot and its tools are off")
    p.add_argument("--native-tools", choices=("auto", "on", "off"),
                   default=os.environ.get("AGY_SHIM_NATIVE_TOOLS", "auto"),
                   help="offer the caller's functions to the CLI as real MCP tools (ADR 0024); "
                        "auto: on when the CLI's configuration names the tools server")
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

    startup_checks(args)
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

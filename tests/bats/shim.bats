#!/usr/bin/env bats
#
# The bridge's tool-call translation. The CLI behind it is an agent, not a model
# API: it answers with a JSON decision that has to become OpenAI tool_calls, and
# a decision that fails to parse must degrade to plain content rather than
# taking the turn down.

setup() {
    SHIM="${BATS_TEST_DIRNAME}/../../bot/agy-shim/agy_shim.py"
    [ -f "$SHIM" ]
}

_render() {                       # a decision this program built -> the OpenAI shape
    python3 - "$SHIM" "$1" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
content, calls = m.decision_to_calls(json.loads(sys.argv[2]))
print(json.dumps({"content": content, "names": [c["function"]["name"] for c in calls],
                  "args": [c["function"]["arguments"] for c in calls]}))
PY
}

# ADR 0027 move 2 deleted the text protocol and the hundred lines of rescue it
# needed - fenced JSON, prose around the envelope, a brace inside a string, an
# envelope abandoned mid-object. None of those shapes can occur any more,
# because a decision is no longer text a model wrote: it is an object built
# from the CLI's structured report of a completed call to the tools server.
# What is left to check is the rendering, and that an unknown shape is refused.

@test "a tool_call becomes one OpenAI tool call" {
    run _render '{"type":"tool_call","name":"send_email","arguments":{"to":"a@example.com"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"names": ["send_email"]'* ]]
    [[ "$output" == *'a@example.com'* ]]
    [[ "$output" == *'"content": ""'* ]]
}

@test "several calls survive as several" {
    run _render '{"type":"tool_calls","calls":[{"name":"a","arguments":{}},{"name":"b","arguments":{}}]}'
    [[ "$output" == *'"names": ["a", "b"]'* ]]
}

@test "a message is content, not a call" {
    run _render '{"type":"message","content":"Hallo"}'
    [[ "$output" == *'"content": "Hallo"'* ]]
    [[ "$output" == *'"names": []'* ]]
}

@test "a shape this program never builds is refused, not guessed at" {
    run _render '{"type":"something-else"}'
    [[ "$output" == *'"names": []'* ]]
    [[ "$output" == *'"content": ""'* ]]
}

@test "the rescue parser and its helpers are gone" {
    ! grep -q 'def parse_decision' "$SHIM"
    ! grep -q 'def unwrap_nested_call' "$SHIM"
    ! grep -q 'TOOL PROTOCOL' "$SHIM"
    ! grep -q '_MESSAGE_ENVELOPE' "$SHIM"
}

@test "the contract names every function and forbids the CLI its own tools" {
    run python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.tool_contract([
    {"function": {"name": "send_email", "description": "Send mail",
                  "parameters": {"type": "object"}}},
    {"function": {"name": "run_shell", "description": "Run a command"}},
]))
PY
    [[ "$output" == *"send_email"* ]]
    [[ "$output" == *"run_shell"* ]]
    [[ "$output" == *"the ONLY"* ]]
    [[ "$output" == *"Never write a tool call as JSON text"* ]]
    [[ "$output" != *"NO tools"* ]]
}

@test "no tools means no contract" {
    run python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("EMPTY" if m.tool_contract([]) == "" else "NOT EMPTY")
PY
    [[ "$output" == *"EMPTY"* ]]
}

@test "the tool contract tells the model its built-in tools are disabled, and the bridge reminds once" {
    grep -q 'those are disabled' "$SHIM"
    grep -q 'TOOL_REMINDER' "$SHIM"
    grep -q '_retry=False' "$SHIM"
}

@test "the bridge frames the system prompt as the authority on the bot's identity" {
    grep -q 'IDENTITY_FRAME_HEAD + system + IDENTITY_FRAME_TAIL' "$SHIM"
    grep -q 'Never present' "$SHIM"
}

@test "the bridge extracts the bot's name from SOUL.md and repeats it every turn" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.identity_name("# Acme News\n\nYour name is **Acme News**. When asked") == "Acme News"
assert m.identity_name("no name here") == ""
assert "you are Acme News" in m.identity_line("Acme News")
assert m.identity_line("") == ""
PY
}

@test "the bridge writes the bot's identity into the CLI's AGENTS.md" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
md = m.agents_md_text("# Acme News\n\nYour name is **Acme News**.")
assert "You are **Acme News**" in md and "never Antigravity" in md and "disabled" in md
assert "take your name from" in m.agents_md_text("")
PY
    grep -q 'agents_md=agents_md_text(system)' "$SHIM"
}

@test "stateless mode renders system, transcript, then the identity line right before the message" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
system = "# Acme News\n\nYour name is **Acme News**."
out = m.stateless_message(system, ["user: hi", "assistant: hello"], "Wer bist du?")
assert out.startswith(m.IDENTITY_FRAME_HEAD), out[:80]
i_sys, i_hist, i_id, i_msg = out.index(system), out.index("CONVERSATION SO FAR"), out.index("OPERATING CONTEXT: In this conversation you are Acme News"), out.rindex("Wer bist du?")
assert i_sys < i_hist < i_id < i_msg
assert out[i_id:i_msg].endswith("Message from the user:\n")
assert "CONVERSATION SO FAR" not in m.stateless_message(system, [], "x")
PY
    grep -q 'AGY_SHIM_STATELESS' "$SHIM"
}

@test "data-url images become files the CLI can read, named in the prompt" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys, base64, os, tempfile
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
png = base64.b64encode(b"\x89PNG\r\n\x1a\nfake").decode()
msgs = [{"role": "user", "content": [{"type": "text", "text": "Was steht da?"},
                                      {"type": "image_url", "image_url": {"url": "data:image/png;base64," + png}}]}]
out, images = m.extract_images(msgs)
assert len(images) == 1 and images[0][1] == "png"
assert out[0]["content"][1] == {"type": "text", "text": "[IMAGE:1]"}
d = tempfile.mkdtemp()
text = m.place_images("Was steht da?\n[IMAGE:1]", images, d)
assert os.path.exists(os.path.join(d, "image-1.png")) and "read the file" in text and "[IMAGE:1]" not in text
plain, none = m.extract_images([{"role": "user", "content": "hi"}])
assert none == [] and plain[0]["content"] == "hi"
PY
}

@test "a denied CLI tool intent becomes a tool call the agent can run" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
intents = [{"name": "list_dir", "parameters": {"DirectoryPath": "/tmp/x y"}},
           {"name": "run_command", "parameters": {"CommandLine": "gh repo list --limit 3"}}]
d = m.map_cli_intents(intents, {"terminal", "read_file"})
assert d == {"type": "tool_call", "name": "terminal", "arguments": {"command": "ls -la '/tmp/x y'"}}, d
d2 = m.map_cli_intents(intents[1:], {"terminal"})
assert d2["arguments"]["command"] == "gh repo list --limit 3"
assert m.map_cli_intents(intents, {"web_search"}) is None          # nothing the caller can run
assert m.map_cli_intents([{"name": "write_to_file", "parameters": {"TargetFile": "/a", "CodeContent": "x"}}], {"write_file"})["arguments"] == {"path": "/a", "content": "x"}
assert m.map_cli_intents([{"name": "run_command", "parameters": {}}], {"terminal"}) is None   # empty command
PY
}

@test "the CLI is spawned without slash-command expansion, with its own switches passed through" {
    grep -q -- '"--disable-slash-commands"' "$SHIM"
    grep -q -- '"--print-timeout"' "$SHIM"
    grep -q 'k.startswith("AGY_CLI_")' "$SHIM"
    grep -q 'AGY_CLI_DISABLE_AUTO_UPDATE=true' "${BATS_TEST_DIRNAME}/../../libs/35-agy-shim.sh"
}

@test "transient CLI failures are their own error type and denied_actions is the primary signal" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert issubclass(m.TransientTurnError, RuntimeError)
src = open(sys.argv[1]).read()
assert 'denied = result.get("denied_actions") or []' in src
assert 'if denied or "permission" in detail.lower()' in src
assert 'permission_mode' in src and 'request-review' in src
PY
}

@test "agent mode: the system prompt becomes a CLI agent definition without tools" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.agent_file_text("# Acme News\n\nYour name is **Acme News**.")
head, body = d.split("---\n", 2)[1], d.split("---\n", 2)[2]
assert "name: hermes" in head and "tools: []" in head and "commandExecutionPolicy: off" in head and "inheritCustomizations: false" in head
assert body.startswith(m.IDENTITY_FRAME_HEAD) and "Acme News" in body
t = m.transcript_message(["user: hi", "assistant: hello"], "Wer bist du?", "Acme News")
assert "CONVERSATION SO FAR" in t and t.endswith("Wer bist du?") and "you are Acme News" in t
assert "CONVERSATION SO FAR" not in m.transcript_message([], "x", "")
PY
    grep -q '"--agent", AGENT_NAME, "--add-dir", self.workdir' "$SHIM"
    grep -q 'AGY_SHIM_AGENT_MODE' "$SHIM"
}

@test "a native call to a caller function is a decision; anything else is not" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys, json
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
step = {"step_type": "tool", "state": "ERROR", "tool_info": {"name": "terminal", "parameters": {"command": "ls"}},
        "error": {"type": "TOOL_ERROR", "message": 'unknown tool: "terminal" — check spelling'}}
d = m.native_call_decision(step, {"terminal", "web_search"})
assert d == {"type": "tool_call", "name": "terminal", "arguments": {"command": "ls"}}, d
assert m.native_call_decision(step, {"web_search"}) is None                      # not a caller function
assert m.native_call_decision(dict(step, state="DONE"), {"terminal"}) is None    # the CLI ran it itself
assert m.native_call_decision(dict(step, error="permission denied"), {"terminal"}) is None
assert m.native_call_decision({"step_type": "agent_response", "state": "DONE"}, {"terminal"}) is None
content, calls = m.decision_to_calls(d)
assert calls and calls[0]["function"]["name"] == "terminal"
assert not hasattr(m, "NATIVE_CALL_REMINDER")      # the text protocol it pointed at is gone
PY
}

@test "the bridge sweeps stale working directories of earlier processes, not fresh ones" {
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/agy-shim-old" "${tmp}/agy-shim-new" "${tmp}/other-dir"
    touch -d '3 hours ago' "${tmp}/agy-shim-old"
    python3 - "$SHIM" "$tmp" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = sys.argv[2]
assert m.sweep_stale_workdirs(root, 3600) == 1
assert sorted(os.listdir(root)) == ["agy-shim-new", "other-dir"], os.listdir(root)
assert m.sweep_stale_workdirs("/nonexistent-dir", 1) == 0
PY
    rm -rf "$tmp"
}

@test "the caller's tools reach the model as real tools: server, allow rule and the unit's switch" {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT DRY_RUN=true
    config_defaults
    # There is no switch any more: without the tools server there is no tool
    # channel at all, so the bridge refuses to start instead of degrading.
    [ -z "${AGY_SHIM_NATIVE_TOOLS:-}" ]
    grep -q 'there is no text fallback' "$REPO_ROOT/bot/agy-shim/agy_shim.py"

    # the merge into the CLI's own two files: additive, idempotent, nothing else touched
    tmp=$(mktemp -d)
    prog=$(_agyshim_merge_program)
    [ "$(python3 -c "$prog" "${tmp}/mcp.json" server tools /usr/bin/python3 /lib/tools_mcp.py)" = changed ]
    [ "$(python3 -c "$prog" "${tmp}/mcp.json" server tools /usr/bin/python3 /lib/tools_mcp.py)" = same ]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["mcpServers"]["tools"]; assert s["command"]=="/usr/bin/python3" and s["args"]==["/lib/tools_mcp.py"], d' "${tmp}/mcp.json"
    printf '{"permissions":{"allow":["command(cat)"]},"model":"m"}' >"${tmp}/settings.json"
    [ "$(python3 -c "$prog" "${tmp}/settings.json" allow 'mcp(tools/*)' -)" = changed ]
    [ "$(python3 -c "$prog" "${tmp}/settings.json" allow 'mcp(tools/*)' -)" = same ]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["model"]=="m" and d["permissions"]["allow"]==["command(cat)","mcp(tools/*)"], d' "${tmp}/settings.json"
    rm -rf "$tmp"

    [ "$(agyshim_tools_script_path)" = /usr/local/lib/hermes-provisioner/tools_mcp.py ]
    grep -q 'agyshim_tools_script_path' "$REPO_ROOT/libs/35-agy-shim.sh"
    ! grep -q -- '--native-tools' "$REPO_ROOT/libs/35-agy-shim.sh"
}

@test "the tools server hands a call over instead of executing it, and the bridge takes it as the decision" {
    python3 - "$SHIM" <<'PY'
import importlib.util, json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import tools_mcp
tools = [{"function": {"name": "web_search", "description": "Search.",
                       "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}}]
d = tempfile.mkdtemp()
m.write_tools_file(d, tools)
srv = tools_mcp.Server(d)
assert [t["name"] for t in srv.handle({"id": 1, "method": "tools/list"})["result"]["tools"]] == ["web_search"]
bad = srv.handle({"id": 2, "method": "tools/call", "params": {"name": "web_search", "arguments": {}}})["result"]
assert bad["isError"] and "missing required 'query'" in bad["content"][0]["text"]
ok = srv.handle({"id": 3, "method": "tools/call", "params": {"name": "web_search", "arguments": {"query": "x"}}})["result"]
assert not ok["isError"] and "caller runs this call" in ok["content"][0]["text"]
step = {"step_type": "tool", "state": "DONE", "tool_info": {"name": "call_mcp_tool",
        "parameters": {"ServerName": "tools", "ToolName": "web_search", "Arguments": {"query": "x"}}}}
assert m.mcp_call_decision(step) == {"type": "tool_call", "name": "web_search", "arguments": {"query": "x"}}
assert m.mcp_call_decision(dict(step, state="ACTIVE")) is None
assert "`tools` server" in m.tool_contract(tools, native=True)
assert '{"type":"tool_call"' not in m.tool_contract(tools, native=True)
PY
    grep -q 'tools_spec=tools' "$SHIM"
    ! grep -q 'AGY_SHIM_NATIVE_TOOLS' "$SHIM"
}

@test "stateful mode with agent mode carries the system prompt once, in the agent definition" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
system = "# Acme News\n\nYour name is **Acme News**."
seeded = {}

class FakeProc:
    def __init__(self, *a, **kw):
        self.kw = kw; self.lock = __import__("threading").Lock(); self.pending_prefix = ""
    def alive(self): return True
    def turn(self, content, timeout): seeded["text"] = content; return {}
    def close(self): pass

m.AgentProcess = FakeProc
pool = types.SimpleNamespace(
    args=types.SimpleNamespace(binary="agy", workdir="/tmp", extra_args=[], agent_mode=True,
                               max_processes=4, timeout=1),
    native_tools=False, procs={}, spares={}, lock=__import__("threading").Lock(),
    _seed_message=m.Pool._seed_message)
proc = m.Pool._get_or_start(pool, "k", ["user: hi"], system, "model-x", None)
assert proc.kw["agent_def"].startswith("---"), "agent definition missing"
assert "Acme News" in proc.kw["agent_def"]
assert "Acme News" not in seeded["text"], "the system prompt was replayed a second time"
assert "user: hi" in seeded["text"]
assert proc.identity == "Acme News"
assert proc.pending_prefix == ""

pool.args.agent_mode = False; pool.procs = {}; seeded.clear()
proc = m.Pool._get_or_start(pool, "k", [], system, "model-x", None)
assert proc.kw["agent_def"] == ""
assert "Acme News" in proc.pending_prefix, "without agent mode the prompt must ride along"
PY
}

@test "a call through the tools server lets the turn finish, so its token counts survive" {
    python3 - "$SHIM" <<'PY'
import importlib.util, json, queue, sys, threading, types
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def fake(events):
    p = types.SimpleNamespace()
    p._events = queue.Queue()
    for e in events:
        p._events.put(e)
    p.proc = types.SimpleNamespace(stdin=types.SimpleNamespace(write=lambda s: None, flush=lambda: None, closed=False), poll=lambda: None)
    p._closed = False; p.turns = 0; p.last_used = 0; p.input_tokens = 0
    p.tool_intents = []; p.native_decision = None; p.available_tools = set(); p.one_shot = True
    p.stderr_tail = lambda: ""
    p.alive = lambda: True
    p.turn = types.MethodType(m.AgentProcess.turn, p)
    p._decision_payload = types.MethodType(m.AgentProcess._decision_payload, p)
    return p

def mcp_step(state, args):
    return {"event": "step_update", "step_update": {"step_type": "tool", "state": state, "tool_info": {
        "name": "call_mcp_tool", "parameters": {"ServerName": "tools", "ToolName": "web_search", "Arguments": args}}}}

# the offered channel: decision taken, the turn still ends normally and the usage survives
res = fake([mcp_step("DONE", {"query": "x"}),
            {"event": "step_update", "step_update": {"step_type": "agent_response", "state": "DONE"}},
            {"event": "result", "result": {"status": "SUCCESS", "response": "pending",
                                           "usage": {"input_tokens": 7000, "cache_read_tokens": 6000, "output_tokens": 40}}}]).turn("hi", 5)
assert res["decision"] == {"type": "tool_call", "name": "web_search", "arguments": {"query": "x"}}, res
assert res["response"] == "", res      # the decision is an object now, never text
assert res["usage"]["input_tokens"] == 7000, res["usage"]

# a turn that dies after the decision still yields the decision
res = fake([mcp_step("DONE", {"query": "x"}),
            {"event": "result", "result": {"status": "ERROR", "error": "improperly formatted function call",
                                           "usage": {"input_tokens": 99}}}]).turn("hi", 5)
assert res["decision"]["name"] == "web_search" and res["usage"]["input_tokens"] == 99

# the broken channel (unknown tool) ends the one-shot turn at once — nothing to wait for
res = fake([{"event": "step_update", "step_update": {"step_type": "tool", "state": "ERROR",
             "tool_info": {"name": "terminal", "parameters": {"command": "ls"}},
             "error": {"message": 'unknown tool: "terminal"'}}}])
res.available_tools = {"terminal"}
out = res.turn("hi", 5)
assert out["native_call"] is True and out["decision"]["name"] == "terminal"
PY
    grep -q 'DECISION_GRACE_SECONDS' "$SHIM"
}

@test "several independent calls in one turn travel together instead of costing a round trip each" {
    python3 - "$SHIM" <<'PY'
import importlib.util, json, queue, sys, types
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def mcp_step(tool, args, state="DONE"):
    return {"event": "step_update", "step_update": {"step_type": "tool", "state": state, "tool_info": {
        "name": "call_mcp_tool", "parameters": {"ServerName": "tools", "ToolName": tool, "Arguments": args}}}}

def fake(events):
    p = types.SimpleNamespace()
    p._events = queue.Queue()
    for e in events:
        p._events.put(e)
    p.proc = types.SimpleNamespace(stdin=types.SimpleNamespace(write=lambda s: None, flush=lambda: None, closed=False), poll=lambda: None)
    p._closed = False; p.turns = 0; p.last_used = 0; p.input_tokens = 0
    p.tool_intents = []; p.native_decision = None; p.available_tools = set(); p.one_shot = True
    p.stderr_tail = lambda: ""; p.alive = lambda: True
    p.turn = types.MethodType(m.AgentProcess.turn, p)
    p._decision_payload = types.MethodType(m.AgentProcess._decision_payload, p)
    return p

done = {"event": "result", "result": {"status": "SUCCESS", "response": "pending", "usage": {"input_tokens": 7000}}}
res = fake([mcp_step("get_me", {}), mcp_step("search_repos", {"query": "acme"}),
            mcp_step("get_me", {}),                                   # the same call twice is one call
            done]).turn("hi", 5)
payload = res["decision"]
assert payload["type"] == "tool_calls", payload
assert [c["name"] for c in payload["calls"]] == ["get_me", "search_repos"], payload
assert res["usage"]["input_tokens"] == 7000

single = fake([mcp_step("get_me", {}), done]).turn("hi", 5)["decision"]
assert single == {"type": "tool_call", "name": "get_me", "arguments": {}}, single

content, calls = m.decision_to_calls(payload)
assert [c["function"]["name"] for c in calls] == ["get_me", "search_repos"], calls
PY
    grep -q 'they travel together' "$(dirname "$SHIM")/tools_mcp.py"
}

@test "a warm process is kept per bot, reused, capped and reaped" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys, threading, time, types
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

made = []
class FakeProc:
    def __init__(self, *a, **kw):
        self.kw = kw; self.created = time.time() + len(made) * 0.001
        self.last_used = self.created; self.closed = False
        made.append(self)
    def alive(self): return not self.closed
    def close(self): self.closed = True

def pool(max_spares=3, agent_mode=True, native=True):
    p = types.SimpleNamespace(
        args=types.SimpleNamespace(binary="agy", workdir="/tmp", extra_args=[], agent_mode=agent_mode,
                                   max_spares=max_spares, idle_timeout=900),
        native_tools=native, procs={}, spares={}, lock=threading.Lock())
    for name in ("_warm_key", "_spawn", "_take_spare", "_warm", "_reaper"):
        setattr(p, name, types.MethodType(getattr(m.Pool, name), p))
    return p

TOOLS_A = [{"function": {"name": "web_search", "parameters": {}}}]
TOOLS_B = [{"function": {"name": "tasks_add", "parameters": {}}}]
SYS_A, SYS_B = "Your name is **A**.", "Your name is **B**."

# the key is model + system + toolset, and nothing else
p = pool()
assert p._warm_key("m", SYS_A, TOOLS_A) == p._warm_key("m", SYS_A, list(TOOLS_A))
assert p._warm_key("m", SYS_A, TOOLS_A) != p._warm_key("m", SYS_B, TOOLS_A)
assert p._warm_key("m", SYS_A, TOOLS_A) != p._warm_key("m", SYS_A, TOOLS_B)
assert p._warm_key("m", SYS_A, TOOLS_A) != p._warm_key("n", SYS_A, TOOLS_A)

m.AgentProcess = FakeProc
# first request spawns; the replacement is warmed in the background
p = pool()
first = p._take_spare("m", SYS_A, TOOLS_A)
for _ in range(200):
    if p.spares: break
    time.sleep(0.01)
assert len(p.spares) == 1, p.spares
# the second request for the SAME bot takes the warm one instead of starting
warm = list(p.spares.values())[0]
second = p._take_spare("m", SYS_A, TOOLS_A)
assert second is warm, "a warm process for this bot was not reused"
assert first is not second

# the process carries this caller's own two files
assert "**A**" in first.kw["agent_def"] and first.kw["tools_spec"] == TOOLS_A
assert first.kw["agents_md"] == ""            # agent mode puts the prompt in the definition

# a dead spare is discarded rather than handed out
p = pool()
p._take_spare("m", SYS_A, TOOLS_A)
for _ in range(200):
    if p.spares: break
    time.sleep(0.01)
list(p.spares.values())[0].closed = True
fresh = p._take_spare("m", SYS_A, TOOLS_A)
assert fresh.alive()

# over the cap, the least recently warmed goes
p = pool(max_spares=2)
for i, (s, t) in enumerate([(SYS_A, TOOLS_A), (SYS_B, TOOLS_A), (SYS_A, TOOLS_B)]):
    p._warm(p._warm_key("m", s, t), "m", s, t)
assert len(p.spares) == 2, p.spares

# max_spares 0 keeps no shelf at all
p = pool(max_spares=0)
p._warm(p._warm_key("m", SYS_A, TOOLS_A), "m", SYS_A, TOOLS_A)
assert p.spares == {}

# the reaper collects a spare nobody came back for
p = pool()
p._warm(p._warm_key("m", SYS_A, TOOLS_A), "m", SYS_A, TOOLS_A)
stale = list(p.spares.values())[0]
stale.created = time.time() - 10_000
t = threading.Thread(target=p._reaper, daemon=True); t.start()
for _ in range(400):
    if not p.spares: break
    time.sleep(0.1)
assert p.spares == {}, "an idle warm process was never retired"
assert stale.closed
PY
    grep -q -- '--max-spares ${AGY_SHIM_MAX_SPARES}' "$REPO_ROOT/libs/35-agy-shim.sh" 2>/dev/null || grep -q -- '--max-spares' "$(dirname "$SHIM")/../../libs/35-agy-shim.sh"
}

@test "a bearer token closes /v1 while /healthz stays open, and the callers are checked" {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT DRY_RUN=true
    config_defaults
    [ "$AGY_SHIM_AUTH" = false ]                       # off by default: loopback is the boundary

    # Off loopback without a token is refused; with one it is a decision.
    _invalid=(); AGY_SHIM_ENABLED=true AGY_SHIM_MODELS=m AGY_SHIM_HOST=0.0.0.0; _validate_agyshim
    [ "${#_invalid[@]}" -ge 1 ]; [[ "${_invalid[*]}" == *AGY_SHIM_AUTH* ]]
    _invalid=(); AGY_SHIM_AUTH=true; _validate_agyshim
    [[ "${_invalid[*]}" != *"reaches beyond loopback"* ]]

    # A caller that would not present the token is named before it fails live.
    AGY_SHIM_HOST=127.0.0.1 AGY_SHIM_PORT=8787
    LLM_ENDPOINT_COUNT=1 LLM_ENDPOINT_1_BASE_URL="http://127.0.0.1:8787/v1" LLM_ENDPOINT_1_TOKEN_VAR=""
    _invalid=(); _check_agyshim_callers_carry_the_token
    [ "${#_invalid[@]}" -eq 1 ]; [[ ${_invalid[0]} == *LLM_ENDPOINT_1_TOKEN_VAR* ]]
    LLM_ENDPOINT_1_TOKEN_VAR="AGY_SHIM_TOKEN"
    _invalid=(); _check_agyshim_callers_carry_the_token; [ "${#_invalid[@]}" -eq 0 ]

    # The token reaches the unit as a FILE, never as an argument or an Environment line.
    grep -q -- '--auth-token-file' "$REPO_ROOT/libs/35-agy-shim.sh"
    ! grep -qE 'Environment=.*TOKEN=' "$REPO_ROOT/libs/35-agy-shim.sh"
    grep -q 'write_file "$file" 0600' "$REPO_ROOT/libs/35-agy-shim.sh"

    # And the endpoint itself: /healthz open, /v1 closed, constant-time compare.
    python3 - "$SHIM" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
h = types.SimpleNamespace(auth_token="", headers={})
ok = types.MethodType(m.Handler._authorized, h)
assert ok() is True                                   # no token configured: everything served
h.auth_token = "sekret"
h.headers = {}
assert ok() is False
h.headers = {"Authorization": "Bearer wrong"}
assert ok() is False
h.headers = {"Authorization": "Basic sekret"}
assert ok() is False
h.headers = {"Authorization": "Bearer sekret"}
assert ok() is True
h.headers = {"Authorization": "bearer  sekret "}       # scheme case and padding
assert ok() is True
src = open(sys.argv[1]).read()
assert "hmac.compare_digest" in src, "the token must not be compared byte by byte"
get = src.split("    def do_GET(self):", 1)[1].split("    def do_POST(self):", 1)[0]
assert get.index('/healthz') < get.index("self._authorized()"), "healthz must be answered before the check"
assert "self._authorized()" in src.split("    def do_POST(self):", 1)[1][:200], "do_POST must check first"
PY
}

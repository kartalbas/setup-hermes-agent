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

_decide() {
    python3 - "$SHIM" "$1" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
content, calls = m.parse_decision(sys.argv[2])
print(json.dumps({"content": content, "names": [c["function"]["name"] for c in calls],
                  "args": [c["function"]["arguments"] for c in calls]}))
PY
}

@test "a tool_call becomes one OpenAI tool call" {
    run _decide '{"type":"tool_call","name":"send_email","arguments":{"to":"a@example.com"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"names": ["send_email"]'* ]]
    [[ "$output" == *'a@example.com'* ]]
    [[ "$output" == *'"content": ""'* ]]
}

@test "several calls survive as several" {
    run _decide '{"type":"tool_calls","calls":[{"name":"a","arguments":{}},{"name":"b","arguments":{}}]}'
    [[ "$output" == *'"names": ["a", "b"]'* ]]
}

@test "a message is content, not a call" {
    run _decide '{"type":"message","content":"Hallo"}'
    [[ "$output" == *'"content": "Hallo"'* ]]
    [[ "$output" == *'"names": []'* ]]
}

@test "a code fence around the JSON is tolerated" {
    run _decide '```json
{"type":"message","content":"fenced"}
```'
    [[ "$output" == *'"content": "fenced"'* ]]
}

@test "prose around the JSON is tolerated" {
    run _decide 'Sicher! {"type":"tool_call","name":"x","arguments":{}} — bitte.'
    [[ "$output" == *'"names": ["x"]'* ]]
}

# A brace inside a string must not end the object early — the naive scan for a
# closing brace truncates the JSON and the whole turn is lost.
@test "a brace inside a string does not end the object" {
    run _decide '{"type":"message","content":"mit } Klammer"}'
    [[ "$output" == *'mit } Klammer'* ]]
}

# Better a passthrough than a failed turn: text that is not a decision is still
# the model telling the user something.
@test "text that is not a decision is returned as content" {
    run _decide 'Einfach nur Text.'
    [[ "$output" == *'"content": "Einfach nur Text."'* ]]
    [[ "$output" == *'"names": []'* ]]
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
    [[ "$output" == *"NO tools"* ]]
    [[ "$output" == *"tool_call"* ]]
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
    grep -q 'DISABLED and auto-denied' "$SHIM"
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

@test "a nested tool_call envelope is unwrapped to the inner call" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys, json
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = {"id": "x", "type": "function", "function": {"name": "tool_call", "arguments": json.dumps({"name": "m365_drive_list", "arguments": {"path": "Secretary"}})}}
out = m.unwrap_nested_call(c)
assert out["function"]["name"] == "m365_drive_list" and json.loads(out["function"]["arguments"]) == {"path": "Secretary"}
plain = {"id": "y", "type": "function", "function": {"name": "m365_whoami", "arguments": "{}"}}
assert m.unwrap_nested_call(plain) == plain
PY
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
content, calls = m.parse_decision(json.dumps(d))
assert calls and calls[0]["function"]["name"] == "terminal"
assert "plain text" in m.NATIVE_CALL_REMINDER
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

@test "a message envelope with real newlines or stray quotes still yields its content" {
    python3 - "$SHIM" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
raw = '{"type":"message","content":"Hier ist die Übersicht:\nZeile zwei\n\nQuelle: X"}'         # raw newlines: invalid JSON, common
content, calls = m.parse_decision(raw)
assert calls == [] and content == "Hier ist die Übersicht:\nZeile zwei\n\nQuelle: X", repr(content)
raw2 = '{"type":"message","content":"Er sagte "schneller" und ging.\nEnde"}'                   # unescaped quotes: only the shape is left
content, calls = m.parse_decision(raw2)
assert calls == [] and content == 'Er sagte "schneller" und ging.\nEnde', repr(content)
content, calls = m.parse_decision('{"type":"tool_call","name":"web_search","arguments":{"q":"a\nb"}}')   # tool call with a raw newline
assert calls and calls[0]["function"]["name"] == "web_search"
PY
}

@test "the caller's tools reach the model as real tools: server, allow rule and the unit's switch" {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT DRY_RUN=true
    config_defaults
    [ "$AGY_SHIM_NATIVE_TOOLS" = auto ]
    _invalid=(); AGY_SHIM_ENABLED=true AGY_SHIM_MODELS=m AGY_SHIM_NATIVE_TOOLS=sometimes; _validate_agyshim
    [ "${#_invalid[@]}" -eq 1 ]
    _invalid=(); AGY_SHIM_NATIVE_TOOLS=off; _validate_agyshim; [ "${#_invalid[@]}" -eq 0 ]

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
    grep -q -- '--native-tools ${AGY_SHIM_NATIVE_TOOLS}' "$REPO_ROOT/libs/35-agy-shim.sh"
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
assert not ok["isError"] and "caller executes" in ok["content"][0]["text"]
step = {"step_type": "tool", "state": "DONE", "tool_info": {"name": "call_mcp_tool",
        "parameters": {"ServerName": "tools", "ToolName": "web_search", "Arguments": {"query": "x"}}}}
assert m.mcp_call_decision(step) == {"type": "tool_call", "name": "web_search", "arguments": {"query": "x"}}
assert m.mcp_call_decision(dict(step, state="ACTIVE")) is None
assert "`tools` server" in m.tool_contract(tools, native=True)
assert '{"type":"tool_call"' not in m.tool_contract(tools, native=True)
PY
    grep -q 'tools_spec=spec' "$SHIM"
    grep -q 'AGY_SHIM_NATIVE_TOOLS' "$SHIM"
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
    return p

def mcp_step(state, args):
    return {"event": "step_update", "step_update": {"step_type": "tool", "state": state, "tool_info": {
        "name": "call_mcp_tool", "parameters": {"ServerName": "tools", "ToolName": "web_search", "Arguments": args}}}}

# the offered channel: decision taken, the turn still ends normally and the usage survives
res = fake([mcp_step("DONE", {"query": "x"}),
            {"event": "step_update", "step_update": {"step_type": "agent_response", "state": "DONE"}},
            {"event": "result", "result": {"status": "SUCCESS", "response": "pending",
                                           "usage": {"input_tokens": 7000, "cache_read_tokens": 6000, "output_tokens": 40}}}]).turn("hi", 5)
assert json.loads(res["response"]) == {"type": "tool_call", "name": "web_search", "arguments": {"query": "x"}}, res
assert res["usage"]["input_tokens"] == 7000, res["usage"]

# a turn that dies after the decision still yields the decision
res = fake([mcp_step("DONE", {"query": "x"}),
            {"event": "result", "result": {"status": "ERROR", "error": "improperly formatted function call",
                                           "usage": {"input_tokens": 99}}}]).turn("hi", 5)
assert json.loads(res["response"])["name"] == "web_search" and res["usage"]["input_tokens"] == 99

# the broken channel (unknown tool) ends the one-shot turn at once — nothing to wait for
res = fake([{"event": "step_update", "step_update": {"step_type": "tool", "state": "ERROR",
             "tool_info": {"name": "terminal", "parameters": {"command": "ls"}},
             "error": {"message": 'unknown tool: "terminal"'}}}])
res.available_tools = {"terminal"}
out = res.turn("hi", 5)
assert out["native_call"] is True and json.loads(out["response"])["name"] == "terminal"
PY
    grep -q 'DECISION_GRACE_SECONDS' "$SHIM"
}

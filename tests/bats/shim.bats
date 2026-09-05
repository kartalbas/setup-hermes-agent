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

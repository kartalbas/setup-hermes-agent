#!/usr/bin/env bats
#
# The agent module's carried patches.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
}

@test "the Teams link patch adds the hrefs of named links to the text, once" {
    tmp=$(mktemp -d)
    cat >"${tmp}/adapter.py" <<'PY'
def handle(activity, text, att):
    for att in getattr(activity, "attachments", None) or []:
        content_url = getattr(att, "content_url", None)
        content_type = (getattr(att, "content_type", None) or "").lower()
        if True:
            if content_type in ("text/html", "text/plain") and not content_url:
                continue
    return text
PY
    hermes_patch_teams_links_file "${tmp}/adapter.py"
    grep -q 'setup-hermes-agent: named links' "${tmp}/adapter.py"
    grep -q '(link: ' "${tmp}/adapter.py"
    bats_run hermes_patch_teams_links_file "${tmp}/adapter.py"; [ "$status" -eq 3 ]
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${tmp}/adapter.py"
    # the patched loop hands the URL over: exercise the generated code with a fake attachment
    python3 - "${tmp}/adapter.py" <<'PY'
import sys, types
ns = {}; exec(open(sys.argv[1]).read(), ns)
att = types.SimpleNamespace(content_url=None, content_type="text/html", content='<p>Bericht: <a href="https://tenant.sharepoint.example/sites/x/Doc.pdf?web=1&amp;e=1">Doc.pdf</a></p>')
activity = types.SimpleNamespace(attachments=[att])
out = ns["handle"](activity, "Bericht: Doc.pdf", None)
assert out == "Bericht: Doc.pdf\n(link: https://tenant.sharepoint.example/sites/x/Doc.pdf?web=1&e=1)", out
PY
    rm -rf "$tmp"
}

@test "the help patch answers a bare /help from HELP.md and leaves /help all alone" {
    tmp=$(mktemp -d)
    cat >"${tmp}/slash_commands.py" <<'PY'
import os
class MessageEvent: pass
class H:
    async def _handle_help_command(self, event: MessageEvent) -> str:
        """Handle /help command - list available commands."""
        return "DEVELOPER LIST"
PY
    hermes_patch_help_file "${tmp}/slash_commands.py"
    grep -q 'setup-hermes-agent: curated help' "${tmp}/slash_commands.py"
    bats_run hermes_patch_help_file "${tmp}/slash_commands.py"; [ "$status" -eq 3 ]
    python3 - "${tmp}" <<'PY'
import asyncio, os, sys, types
tmp = sys.argv[1]
os.makedirs(os.path.join(tmp, "home"), exist_ok=True)
open(os.path.join(tmp, "home", "HELP.md"), "w").write("**Bot**\nshort help\n")
run = types.ModuleType("gateway.run"); run._hermes_home = os.path.join(tmp, "home")
gw = types.ModuleType("gateway"); gw.run = run
sys.modules["gateway"] = gw; sys.modules["gateway.run"] = run
ns = {}; exec(open(os.path.join(tmp, "slash_commands.py")).read(), ns)
class Ev:
    def __init__(self, a): self.a = a
    def get_command_args(self): return self.a
h = ns["H"]()
assert asyncio.run(h._handle_help_command(Ev(""))) == "**Bot**\nshort help"
assert asyncio.run(h._handle_help_command(Ev("all"))) == "DEVELOPER LIST"
assert asyncio.run(h._handle_help_command(Ev("skills"))) == "DEVELOPER LIST"
PY
    rm -rf "$tmp"
}

@test "the choice patch turns the numbered fallback into a list, once, and keeps the numbers" {
    local f; f=$(mktemp --suffix=.py)
    cat >"$f" <<'PY'
class Adapter:
    async def send_clarify(self, chat_id, question, choices, clarify_id, session_key, metadata=None):
        if choices:
            _is_multi = False
            lines = [f"❓ {question}", ""]
            for i, choice in enumerate(choices, start=1):
                lines.append(f"  {i}. {choice}")
            lines.append("")
            lines.append("Reply with the number, the option text, or your own answer.")
            text = "\n".join(lines)
        else:
            text = f"❓ {question}"
        return text
PY
    hermes_patch_clarify_choices_file "$f"
    grep -q 'lines.append(f"- \*\*{i}\.\*\* {choice}")' "$f"
    ! grep -q 'lines.append(f"  {i}. {choice}")' "$f"
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f"
    # every option on its own line, the number still answerable
    out=$(python3 - "$f" <<'PY'
import asyncio, importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(asyncio.run(m.Adapter().send_clarify("c", "Welcher Tenant?", ["Acme", "Globex"], "id", "s")))
PY
)
    [[ "$out" == *'- **1.** Acme'* && "$out" == *'- **2.** Globex'* ]]
    [[ "$out" == *'Reply with the number'* ]]
    bats_run hermes_patch_clarify_choices_file "$f"
    [ "$status" -eq 3 ]
    [ "$(hermes_adapter_base_path)" = "$(hermes_install_dir)/gateway/platforms/base.py" ]
    rm -f "$f"
}

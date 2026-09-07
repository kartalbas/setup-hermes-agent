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

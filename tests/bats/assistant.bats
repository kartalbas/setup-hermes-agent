#!/usr/bin/env bats
#
# The assistant module's pure parts: the MCP registration it writes, and the
# scope comparison that decides whether to touch the app registration.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
    ASSISTANT_M365_TIMEZONE="Europe/Zurich"
}

@test "the m365 registration names the venv python, the server script and its env" {
    out=$(_assistant_m365_fragment tenant-1 client-1 agent@example.com)
    [[ $out == *'command: "/var/lib/hermes-assistant/venv/bin/python"'* ]]
    [[ $out == *'args: ["/usr/local/lib/hermes-assistant/m365_assistant.py", "serve"]'* ]]
    [[ $out == *'M365_ACCOUNT: "agent@example.com"'* ]]
    [[ $out == *'M365_TOKEN_FILE: "/var/lib/hermes-assistant/m365.token"'* ]]
    [[ $out == *'M365_SCOPES: "offline_access openid profile'* ]]
    [[ $out == *'enabled: true'* ]]
}

@test "the registration is valid yaml with the env as a map" {
    _assistant_m365_fragment tenant-1 client-1 agent@example.com | python3 -c '
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(0)  # the agent venv has PyYAML; the test host may not
d = yaml.safe_load(sys.stdin)
m = d["mcp_servers"]["m365"]
assert m["env"]["M365_TENANT_ID"] == "tenant-1" and m["timeout"] == 120, m
'
}

@test "missing scopes are the wanted ones not already declared" {
    out=$(_az_missing_scopes "a b c" "b")
    [ "$out" = $'a\nc' ]
    [ -z "$(_az_missing_scopes "a b" "b a extra")" ]
}

@test "an enabled assistant needs an account that looks like a sign-in" {
    ASSISTANT_M365_ENABLED=true ASSISTANT_M365_ACCOUNT=""
    bats_run config_validate
    [ "$status" -ne 0 ]
    ASSISTANT_M365_ACCOUNT="not-an-address"
    bats_run config_validate
    [ "$status" -ne 0 ]
}

@test "the scope comparison splits on spaces even under the installer's IFS" {
    local IFS=$'\n\t'
    out=$(_az_missing_scopes "a b c" "b")
    [ "$out" = $'a\nc' ]
}

@test "the env file quotes its values so the scope list survives being sourced" {
    DRY_RUN=false
    ASSISTANT_STATE_DIR=$(mktemp -d); ASSISTANT_LIB_DIR="${ASSISTANT_STATE_DIR}/lib"; ASSISTANT_VENV="${ASSISTANT_STATE_DIR}/venv"
    SERVICE_USER=$(id -un); SERVICE_GROUP=$(id -gn)
    mkdir -p "$ASSISTANT_LIB_DIR"
    _assistant_m365_wrapper tenant-1 client-1 agent@example.com
    ( set -a; . "${ASSISTANT_STATE_DIR}/m365.env"; [ "$M365_ACCOUNT" = agent@example.com ]; [[ $M365_SCOPES == "offline_access openid"* ]] )
    [ -x "${ASSISTANT_LIB_DIR}/m365ctl" ]
    rm -rf "$ASSISTANT_STATE_DIR"
}

@test "the google registration runs the wrapper, keeping the client secret out of config.yaml" {
    out=$(_assistant_google_fragment)
    [[ $out == *'command: "/usr/local/lib/hermes-assistant/googlectl"'* ]]
    [[ $out == *'args: ["serve"]'* ]]
    [[ $out != *SECRET* ]]
}

@test "a bot may list google only when the google side is enabled" {
    BOTS="secretary" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    ASSISTANT_GOOGLE_ENABLED=false BOT_SECRETARY_MCP="google"
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 1 ]
    ASSISTANT_GOOGLE_ENABLED=true
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 0 ]
}

@test "the github registration runs the wrapper; the token stays in the env file" {
    out=$(_assistant_github_fragment)
    [[ $out == *'command: "/usr/local/lib/hermes-assistant/githubctl"'* ]]
    [[ $out == *'args: ["stdio"]'* ]]
    [[ $out != *TOKEN* ]]
}

@test "a bot may list github only when the github side is enabled" {
    BOTS="github" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    ASSISTANT_GITHUB_ENABLED=false BOT_GITHUB_MCP="github"
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 1 ]
    ASSISTANT_GITHUB_ENABLED=true
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 0 ]
}

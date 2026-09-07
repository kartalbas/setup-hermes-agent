#!/usr/bin/env bats
#
# The admin tooling: opsctl's pure parts and the module's configuration file.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    SERVICE_USER=$(id -un)
    config_defaults
}

@test "changed paths map to the installer modules that apply them" {
    [ "$(bash "$REPO_ROOT/bot/ops/opsctl" modules-for bot/roles/admin.md libs/80-channels.sh docs/plan.md)" = "profiles,channels" ]
    [ "$(bash "$REPO_ROOT/bot/ops/opsctl" modules-for README.md tests/bats/x.bats)" = none ]
    [ "$(bash "$REPO_ROOT/bot/ops/opsctl" modules-for libs/20-config.sh bot/roles/x.md)" = all ]
    [ "$(bash "$REPO_ROOT/bot/ops/opsctl" modules-for bot/agy-shim/agy_shim.py bot/mcp/m365_assistant.py bot/ops/opsctl)" = "agyshim,assistant,ops" ]
}

@test "opsctl without a configuration file says so instead of guessing" {
    OPSCTL_CONF=/nonexistent/ops.conf bats_run bash "$REPO_ROOT/bot/ops/opsctl" status
    [ "$status" -ne 0 ]
    [[ "$output" == *"no configuration"* ]]
}

@test "the configuration names the repository, the bots and the CLI, and holds no secret" {
    BOTS="secretary admin" BOT_SERVICE_PREFIX=acme SERVICE_NAME=agent-gw HERMES_REPO=vendor/agent HERMES_REF=v1 ASSISTANT_GITHUB_MCP_VERSION=1.2.3
    out=$(ops_conf_text)
    [[ $out == *"OPS_REPO=${REPO_ROOT}"* ]]
    [[ $out == *'OPS_BOTS="secretary admin"'* ]]
    [[ $out == *'OPS_SERVICE_PREFIX=acme'* && $out == *'OPS_SERVICE_NAME=agent-gw'* ]]
    [[ $out == *'OPS_CLAUDE_MODEL=opus'* && $out == *'OPS_HERMES_REF=v1'* && $out == *'OPS_GITHUB_MCP_VERSION=1.2.3'* ]]
    [[ $out != *KEY* && $out != *SECRET* && $out != *TOKEN* ]]
}

@test "ops validation wants a numeric timeout and a model, and nothing when switched off" {
    OPS_ENABLED=false OPS_CLAUDE_TIMEOUT=soon; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 0 ]
    OPS_ENABLED=true; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 1 ]; [[ ${_invalid[0]} == *OPS_CLAUDE_TIMEOUT* ]]
    OPS_CLAUDE_TIMEOUT=900 OPS_CLAUDE_MODEL=""; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 1 ]; [[ ${_invalid[0]} == *OPS_CLAUDE_MODEL* ]]
    OPS_CLAUDE_MODEL=opus; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 0 ]
}

@test "OPS_APPLY takes auto, ask or never, and the configuration carries it" {
    OPS_ENABLED=true OPS_CLAUDE_TIMEOUT=900 OPS_CLAUDE_MODEL=opus
    OPS_APPLY=sometimes; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 1 ]
    OPS_APPLY=auto; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 0 ]
    BOTS="admin" BOT_SERVICE_PREFIX=acme SERVICE_NAME=agent-gw
    [[ $(ops_conf_text) == *'OPS_APPLY=auto'* ]]
}

@test "apply refuses when switched off, before touching anything" {
    tmp=$(mktemp -d)
    printf 'OPS_REPO=%s\nOPS_SERVICE_NAME=x\nOPS_SERVICE_PREFIX=y\nOPS_BOTS=a\nOPS_STATE=%s\nOPS_APPLY=never\n' "$REPO_ROOT" "$tmp" >"${tmp}/ops.conf"
    OPSCTL_CONF="${tmp}/ops.conf" bats_run bash "$REPO_ROOT/bot/ops/opsctl" apply channels
    [ "$status" -ne 0 ]; [[ "$output" == *"switched off"* ]]
    OPSCTL_CONF="${tmp}/ops.conf" bats_run bash "$REPO_ROOT/bot/ops/opsctl" apply-status
    [ "$status" -eq 0 ]; [[ "$output" == *"no apply has been run"* ]]
    rm -rf "$tmp"
}

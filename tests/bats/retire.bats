#!/usr/bin/env bats
#
# Taking a subscription CLI off a host: the bridge switched off is removed,
# not left running — its unit, scripts, token, ACP server and harness, but not
# the balance proxy that shares its directory — and a CLI named in CLIS_REMOVE
# goes with its binary, its data and its sign-in.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=false
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
    SERVICE_NAME=retire-test                         # a unit name no host has
    AGY_SHIM_LIB_DIR=$(mktemp -d)
    AGY_SHIM_TOKEN_FILE="${AGY_SHIM_LIB_DIR}/bridge.token"
    AGY_SHIM_ACP_SERVER="${AGY_SHIM_LIB_DIR}/agy_acp_server.par"
    CALLS=$(mktemp)
    systemctl() {                                     # a unit that is installed, calls noted
        printf '%s\n' "$*" >>"$CALLS"
        [[ $1 == list-unit-files ]] && printf '%s 0\n' "$2"
        return 0
    }
    have_cmd() { [[ $1 == systemctl ]] || command -v "$1" >/dev/null; }
    require_root() { :; }
}

teardown() { rm -rf "$AGY_SHIM_LIB_DIR" "$CALLS" "${HOME_DIR:-/nonexistent}"; }

bridge_files() {
    local f
    for f in agy_shim.py tools_mcp.py acp_seed_token.py VERSION bridge.token agy_acp_server.par localharness_external; do
        printf 'x\n' >"${AGY_SHIM_LIB_DIR}/${f}"
    done
    printf 'proxy\n' >"${AGY_SHIM_LIB_DIR}/balance_proxy.py"   # the apiproxy module's, beside it
}

@test "the bridge switched off is removed — unit, scripts, token, ACP server, harness — and the balance proxy stays" {
    bridge_files
    AGY_SHIM_ENABLED=false
    agyshim_apply
    [ "$(ls "$AGY_SHIM_LIB_DIR")" = balance_proxy.py ]
    grep -qx "disable --now retire-test-bridge.service" "$CALLS"
    # gone is gone: the next run has nothing to do
    : >"$CALLS"
    systemctl() { printf '%s\n' "$*" >>"$CALLS"; return 0; }
    _agyshim_present && false
    agyshim_apply
    ! grep -q "disable" "$CALLS"
}

@test "a CLI in CLIS_REMOVE goes with its binary, its data and sign-in, and what that leaves empty — nothing else" {
    HOME_DIR=$(mktemp -d)
    mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/.gemini/antigravity-cli" "$HOME_DIR/.gemini/config" "$HOME_DIR/.cache/antigravity" "$HOME_DIR/.cache/other"
    printf 'bin\n' >"$HOME_DIR/.local/bin/agy"
    printf 'claude\n' >"$HOME_DIR/.local/bin/claude"
    printf 'token\n' >"$HOME_DIR/.gemini/antigravity-cli/antigravity-oauth-token"
    printf '{}\n' >"$HOME_DIR/.gemini/config/mcp_config.json"
    CLI_DATA_AGY=".gemini/antigravity-cli .gemini/config .cache/antigravity ../escape /etc"
    _cli_remove agy "$HOME_DIR"
    [ ! -e "$HOME_DIR/.local/bin/agy" ] && [ -e "$HOME_DIR/.local/bin/claude" ]
    [ ! -e "$HOME_DIR/.gemini" ]                                 # emptied, so gone
    [ ! -e "$HOME_DIR/.cache/antigravity" ] && [ -d "$HOME_DIR/.cache/other" ]
    # nothing left: said so, and no change counted
    before=$CHANGE_COUNT
    _cli_remove agy "$HOME_DIR"
    [ "$CHANGE_COUNT" -eq "$before" ]
}

@test "the catalogue names agy's data, and a CLI cannot be installed and removed at once" {
    grep -qE '^CLI_DATA_AGY=".*\.gemini/antigravity-cli' "$REPO_ROOT/config/install.conf"
    IFS=$'\n\t'                                      # as in install.sh
    CLIS_INSTALL=$'agy\n  claude' CLIS_REMOVE="gemini agy"   # a wrapped list too
    _invalid=(); _check_clis_remove
    [[ "${_invalid[*]}" == *"CLIS_INSTALL and CLIS_REMOVE both name 'agy'"* ]]
    [[ "${_invalid[*]}" != *"'gemini'"* ]]
}

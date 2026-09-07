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

@test "the CLI paths are derived from the service account's home, never from a placeholder" {
    unset OPS_CLAUDE_BIN OPS_AGY_BIN SERVICE_USER BOOTSTRAP_USER
    config_defaults                                   # first pass: no account known yet
    [ -z "${OPS_CLAUDE_BIN:-}" ]
    SERVICE_USER=$(id -un); config_defaults           # second pass, as install.sh does
    [ "$OPS_CLAUDE_BIN" = "${HOME}/.local/bin/claude" ]
    [ "$OPS_AGY_BIN" = "${HOME}/.local/bin/agy" ]
    [[ $OPS_CLAUDE_BIN != *nonexistent* ]]
    unset OPS_CLAUDE_BIN OPS_AGY_BIN; OPS_ENABLED=true OPS_CLAUDE_TIMEOUT=900 OPS_CLAUDE_MODEL=opus OPS_APPLY=ask
    _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 1 ]; [[ ${_invalid[0]} == *OPS_CLAUDE_BIN* ]]
}

@test "OPS_APPLY takes auto, ask or never, and the configuration carries it" {
    OPS_ENABLED=true OPS_CLAUDE_TIMEOUT=900 OPS_CLAUDE_MODEL=opus
    OPS_APPLY=sometimes; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 1 ]
    OPS_APPLY=auto; _invalid=(); _check_ops; [ "${#_invalid[@]}" -eq 0 ]
    BOTS="admin" BOT_SERVICE_PREFIX=acme SERVICE_NAME=agent-gw
    [[ $(ops_conf_text) == *'OPS_APPLY=auto'* ]]
}

@test "apply refuses when switched off or without the applier, and never escalates itself" {
    tmp=$(mktemp -d)
    printf 'OPS_REPO=%s\nOPS_SERVICE_NAME=x\nOPS_SERVICE_PREFIX=y\nOPS_BOTS=a\nOPS_STATE=%s\nOPS_APPLY=never\n' "$REPO_ROOT" "$tmp" >"${tmp}/ops.conf"
    OPSCTL_CONF="${tmp}/ops.conf" bats_run bash "$REPO_ROOT/bot/ops/opsctl" apply channels
    [ "$status" -ne 0 ]; [[ "$output" == *"switched off"* ]]
    sed -i 's/OPS_APPLY=never/OPS_APPLY=auto/' "${tmp}/ops.conf"
    OPSCTL_CONF="${tmp}/ops.conf" OPSCTL_APPLIER_PATH=no-such-applier.path bats_run bash "$REPO_ROOT/bot/ops/opsctl" apply channels
    [ "$status" -ne 0 ]; [[ "$output" == *"applier"* ]]                  # the applier is not active: refused, nothing written
    [ ! -f "${tmp}/apply.request" ]
    OPSCTL_CONF="${tmp}/ops.conf" bats_run bash "$REPO_ROOT/bot/ops/opsctl" apply-status
    [ "$status" -eq 0 ]; [[ "$output" == *"no apply has been run"* ]]
    ! grep -qE '\bsudo\b' "$REPO_ROOT/bot/ops/opsctl"
    rm -rf "$tmp"
}

@test "the applier consumes the request, runs the installer once and leaves a readable log" {
    tmp=$(mktemp -d); mkdir -p "${tmp}/repo" "${tmp}/state"
    printf '#!/usr/bin/env bash\nprintf "args: %%s\\n" "$*"; exit 0\n' >"${tmp}/repo/install.sh"; chmod 755 "${tmp}/repo/install.sh"
    printf 'profiles,channels\n' >"${tmp}/state/apply.request"
    OPS_REPO="${tmp}/repo" OPS_STATE="${tmp}/state" OPS_GROUP=$(id -gn) bash "$REPO_ROOT/bot/ops/apply.sh"
    [ ! -f "${tmp}/state/apply.request" ]
    log=$(ls "${tmp}"/state/apply-*.log)
    grep -q 'args: --only profiles,channels' "$log"; grep -q 'exit=0' "$log"
    grep -q 'state=finished exit=0' "${tmp}/state/apply-last"
    OPS_REPO="${tmp}/repo" OPS_STATE="${tmp}/state" bash "$REPO_ROOT/bot/ops/apply.sh"     # no request: nothing happens
    [ "$(ls "${tmp}"/state/apply-*.log | wc -l)" -eq 1 ]
    rm -rf "$tmp"
}

@test "the applier units run the script as root from the repository and watch the request file" {
    SCRIPT_DIR=$REPO_ROOT SERVICE_GROUP=agents
    out=$(ops_applier_service_text)
    [[ $out == *"WorkingDirectory=${REPO_ROOT}"* && $out == *'ExecStart=/usr/local/lib/hermes-ops/apply.sh'* && $out == *'Environment=OPS_GROUP=agents'* && $out != *User=* ]]
    out=$(ops_applier_path_text)
    [[ $out == *'PathExists=/var/lib/hermes-ops/apply.request'* && $out == *'Unit=hermes-ops-apply.service'* ]]
}

@test "Claude Code's allowlist reads the host but never writes to it" {
    out=$(bash -c 'source "$1"; allowed_tools' _ "$REPO_ROOT/bot/ops/opsctl")
    [[ $out == *'Bash(journalctl:*)'* && $out == *'Bash(opsctl status)'* && $out == *'Bash(m365ctl inbox)'* && $out == *'Bash(tests/run.sh:*)'* ]]
    [[ $out != *sudo* && $out != *'systemctl restart'* && $out != *install.sh* && $out != *'git push'* && $out != *'m365ctl migrate'* && $out != *'opsctl apply)'* && $out != *'opsctl change'* ]]
    [[ $out != *companions\ --apply* ]]
}

# shellcheck shell=bash
#
# The Admin bot's hands: `opsctl`, a wrapper with a few fixed commands (status,
# report, check-updates, dry-run, change) installed on the PATH, and the
# configuration it reads. The `change` command runs Claude Code inside the
# repository checkout with the model OPS_CLAUDE_MODEL; the CLI is the service
# account's (clis module), signed in through the operator's subscription.
#
# Applying is a separate, deterministic step: `opsctl apply` runs the installer
# as a transient systemd unit (OPS_APPLY: auto after a green change, ask, or
# never). Claude Code itself never gets the installer, systemctl or sudo.
#
# Order: after `assistant`, before `dashboard`.

ops_apply() {
    is_true "${OPS_ENABLED:-false}" || { log_skip "admin tooling disabled (OPS_ENABLED=false)"; return 0; }
    log_step "Admin tooling"
    _ops_install_wrapper
    _ops_write_conf
    _ops_state_dir
    _ops_verify
}

ops_conf_text() {                 # -> the wrapper's configuration (no secrets)
    local bots
    bots=$(bots | tr '\n' ' '); bots=${bots% }
    cat <<EOF
# Managed by setup-hermes-agent: what opsctl needs to know about this host.
OPS_REPO=${SCRIPT_DIR}
OPS_SERVICE_NAME=${SERVICE_NAME}
OPS_SERVICE_PREFIX=${BOT_SERVICE_PREFIX}
OPS_BOTS="${bots}"
OPS_STATE=${OPS_STATE_DIR}
OPS_BRIDGE_PORT=${AGY_SHIM_PORT:-8787}
OPS_CLAUDE=${OPS_CLAUDE_BIN}
OPS_CLAUDE_MODEL=${OPS_CLAUDE_MODEL}
OPS_CLAUDE_TIMEOUT=${OPS_CLAUDE_TIMEOUT}
OPS_APPLY=${OPS_APPLY}
OPS_HERMES_REPO=${HERMES_REPO}
OPS_HERMES_REF=${HERMES_REF}
OPS_GITHUB_MCP_VERSION=${ASSISTANT_GITHUB_MCP_VERSION}
OPS_AGY=${OPS_AGY_BIN}
EOF
}

_ops_install_wrapper() {
    local src="${SCRIPT_DIR}/bot/ops/opsctl"
    [[ -f $src ]] || die "bot/ops/opsctl is missing"
    if [[ $DRY_RUN == true ]]; then log_info "[dry-run] install ${src} -> ${OPS_BIN}"; return 0; fi
    write_file "$OPS_BIN" 0755 <<<"$(cat "$src")"
}

_ops_write_conf() {
    if [[ $DRY_RUN == true ]]; then log_info "[dry-run] write ${OPS_CONF}"; return 0; fi
    write_file "$OPS_CONF" 0644 <<<"$(ops_conf_text)"
}

_ops_state_dir() {
    ensure_dir "$OPS_STATE_DIR" 0750 "${SERVICE_USER}:${SERVICE_GROUP}"
}

_ops_verify() {
    [[ $DRY_RUN == true ]] && return 0
    [[ -x $OPS_CLAUDE_BIN ]] || defer_failure "ops: Claude Code not found at ${OPS_CLAUDE_BIN}; add claude to CLIS_INSTALL and sign in as ${SERVICE_USER}"
    local out
    if out=$(runuser -u "$SERVICE_USER" -- "$OPS_BIN" report 2>&1); then
        log_ok "opsctl report: $(head -n1 <<<"$out")"
    else
        defer_failure "ops: opsctl report failed: $(tail -n2 <<<"$out")"
    fi
}

ops_uninstall() { run rm -f "$OPS_BIN" "$OPS_CONF"; run rm -rf "$OPS_STATE_DIR"; }

# shellcheck shell=bash
#
# The assistant — the agent's hands in Microsoft 365 (and, in its own part,
# Google): MCP servers from bot/mcp/, installed into their own virtualenv and
# registered in the agent's config.yaml under mcp_servers.
#
# One account per world. The Microsoft 365 server acts as the agent's mailbox
# account and signs in once with a device code — the same shape as the mail
# relay, for the same reason: no client secret on the host, a refresh token
# the server renews on its own, and an identity check so the token can never
# belong to someone else.
#
# The delegated scopes are declared on the app registration by this module
# (az) when AZURE_MANAGE is on, and admin-consented so the sign-in never shows
# a consent screen the account may not be allowed to accept.
#
# Order: after `channels` (config.yaml exists and the providers are in) and
# before `dashboard`. The gateway is restarted here only if this module changed
# something.

assistant_python() { printf '%s/bin/python' "$ASSISTANT_VENV"; }
assistant_m365_token_file() { printf '%s/m365.token' "$ASSISTANT_STATE_DIR"; }

assistant_apply() {
    local before=$CHANGE_COUNT

    if ! is_true "${ASSISTANT_M365_ENABLED:-false}"; then
        _assistant_disable m365
        return 0
    fi

    _assistant_venv
    _assistant_install_code
    _assistant_m365
    (( $(bot_count) == 0 )) && converge_unit "${SERVICE_NAME}.service" "$before"
    return 0
}

# ---------------------------------------------------------------------------
# The virtualenv: python3 (a preflight requirement) plus the two document
# libraries, pinned. Nothing else — the servers use the standard library.
# ---------------------------------------------------------------------------
_assistant_venv() {
    local py; py=$(assistant_python)
    # An array, not a string: IFS is newline/tab in this program, so an unquoted
    # string would reach pip as one requirement.
    local -a pins=("pypdf==${ASSISTANT_PYPDF_VERSION}" "python-docx==${ASSISTANT_DOCX_VERSION}")

    if [[ $DRY_RUN != true && -x $py ]] && "$py" - "$ASSISTANT_PYPDF_VERSION" "$ASSISTANT_DOCX_VERSION" <<'PY' 2>/dev/null
import sys
from importlib.metadata import version
sys.exit(0 if (version("pypdf"), version("python-docx")) == tuple(sys.argv[1:]) else 1)
PY
    then
        log_skip "assistant environment present at ${ASSISTANT_VENV}"
        return 0
    fi

    require_cmd python3
    ensure_dir "$ASSISTANT_STATE_DIR" 0700 "${SERVICE_USER}:${SERVICE_GROUP}"
    log_info "installing the assistant environment into ${ASSISTANT_VENV} (${pins[*]})"
    [[ -x $py ]] || run python3 -m venv "$ASSISTANT_VENV"
    run "$py" -m pip install --quiet --upgrade pip
    run "$py" -m pip install --quiet "${pins[@]}"
    run chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$ASSISTANT_VENV"
    mark_changed
}

# The servers themselves, copied from bot/mcp/ — write_file compares, so an
# unchanged bot is not a change and does not restart the gateway.
_assistant_install_code() {
    local src="${SCRIPT_DIR}/bot/mcp" f
    [[ -f ${src}/assistant_common.py && -f ${src}/m365_assistant.py ]] ||
        die "bot/mcp is incomplete under ${src}"
    ensure_dir "$ASSISTANT_LIB_DIR" 0755
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] install bot/mcp/*.py -> ${ASSISTANT_LIB_DIR} (bot $(bot_version))"
        return 0
    fi
    for f in "$src"/*.py; do
        write_file "${ASSISTANT_LIB_DIR}/$(basename "$f")" 0644 <<<"$(cat "$f")"
    done
    write_file "${ASSISTANT_LIB_DIR}/VERSION" 0644 <<<"$(bot_version)"
}

# ---------------------------------------------------------------------------
# Microsoft 365
# ---------------------------------------------------------------------------
_assistant_m365() {
    local account=$ASSISTANT_M365_ACCOUNT tenant client
    tenant=$(secret_require "$ASSISTANT_M365_TENANT_ID_VAR" "the assistant (M365 tenant)")
    client=$(secret_require "$ASSISTANT_M365_CLIENT_ID_VAR" "the assistant (M365 client id)")
    log_info "assistant      m365 as ${account}"

    _assistant_m365_wrapper "$tenant" "$client" "$account"
    _assistant_m365_signin "$tenant" "$client" "$account"
    _assistant_m365_folder "$tenant" "$client" "$account"
    _assistant_m365_register_all "$tenant" "$client" "$account"
}

# Registration goes into every profile that lists the server in its MCP field;
# the others carry it as enabled: false. Without bots, the default profile.
_assistant_m365_register_all() {
    if (( $(bot_count) == 0 )); then
        _assistant_m365_register "$@"
        return 0
    fi
    local key before
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"
        before=$CHANGE_COUNT
        if bot_has_mcp "$key" m365; then
            _assistant_m365_register "$@"
        else
            _assistant_disable m365
        fi
        converge_unit "${BOT_SERVICE}.service" "$before"
        bot_context_end
    done < <(bots)
}

# The working folder in the agent's OneDrive, shared with the operator so
# nothing the agent files is out of the operator's reach. Idempotent: the
# server keeps existing grants and only adds what is missing.
_assistant_m365_folder() {
    [[ -n ${ASSISTANT_M365_ROOT_FOLDER:-} ]] || return 0
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] ensure OneDrive folder '${ASSISTANT_M365_ROOT_FOLDER}' shared (${ASSISTANT_M365_SHARE_ROLE}) with ${ASSISTANT_M365_SHARE_WITH:-nobody}"
        return 0
    fi
    [[ -s $(assistant_m365_token_file) ]] || { log_skip "no token yet; the folder is created after the sign-in"; return 0; }
    local out
    if out=$(sudo -u "$SERVICE_USER" "$(assistant_m365ctl)" \
            ensure-folder "$ASSISTANT_M365_ROOT_FOLDER" "${ASSISTANT_M365_SHARE_WITH:-}" "$ASSISTANT_M365_SHARE_ROLE" 2>&1); then
        local granted
        granted=$(jq -r '.share.granted_now // [] | join(",")' <<<"$out" 2>/dev/null)
        if [[ -n $granted ]]; then
            mark_changed; log_ok "OneDrive folder '${ASSISTANT_M365_ROOT_FOLDER}' shared (${ASSISTANT_M365_SHARE_ROLE}) with ${granted}"
        else
            log_skip "OneDrive folder '${ASSISTANT_M365_ROOT_FOLDER}' present and shared"
        fi
    else
        defer_failure "assistant: could not ensure the OneDrive folder '${ASSISTANT_M365_ROOT_FOLDER}': ${out}"
    fi
}

# The env the server runs with. Nothing here is secret: the client id is a
# public client, and the token lives in its own 0600 file.
_assistant_m365_env_lines() {      # _assistant_m365_env_lines TENANT CLIENT ACCOUNT -> "K=V" lines
    printf 'M365_TENANT_ID=%s\nM365_CLIENT_ID=%s\nM365_ACCOUNT=%s\nM365_TOKEN_FILE=%s\nM365_TIMEZONE=%s\nM365_SCOPES=%s\n' \
        "$1" "$2" "$3" "$(assistant_m365_token_file)" "$ASSISTANT_M365_TIMEZONE" "$ASSISTANT_M365_SCOPES"
}

_assistant_m365_fragment() {       # _assistant_m365_fragment TENANT CLIENT ACCOUNT -> yaml
    local line
    cat <<EOF
mcp_servers:
  m365:
    enabled: true
    command: "$(assistant_python)"
    args: ["${ASSISTANT_LIB_DIR}/m365_assistant.py", "serve"]
    timeout: 120
    connect_timeout: 30
    env:
EOF
    while IFS= read -r line; do
        printf '      %s: "%s"\n' "${line%%=*}" "${line#*=}"
    done < <(_assistant_m365_env_lines "$@")
}

# The same env as a file plus a wrapper, so the module and an operator run the
# server's commands the same way: `m365ctl status`. Nothing in it is secret.
assistant_m365_env_file() { printf '%s/m365.env' "$ASSISTANT_STATE_DIR"; }
assistant_m365ctl() { printf '%s/m365ctl' "$ASSISTANT_LIB_DIR"; }

_assistant_m365_wrapper() {
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write $(assistant_m365_env_file) and $(assistant_m365ctl)"
        return 0
    fi
    # Values are single-quoted: the scope list has spaces and the file is sourced.
    write_file "$(assistant_m365_env_file)" 0640 "${SERVICE_USER}:${SERVICE_GROUP}" \
        <<<"$(_assistant_m365_env_lines "$@" | sed "s/^\([A-Z_0-9]*\)=\(.*\)$/\1='\2'/")"
    write_file "$(assistant_m365ctl)" 0755 <<EOF
#!/usr/bin/env bash
# Runs the Microsoft 365 assistant's commands with its configured environment:
#   m365ctl status | login | ensure-folder PATH [EMAILS [read|write]] | tools | serve
set -euo pipefail
set -a; . "$(assistant_m365_env_file)"; set +a
exec "$(assistant_python)" "${ASSISTANT_LIB_DIR}/m365_assistant.py" "\$@"
EOF
}

_assistant_m365_register() {
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] register mcp_servers.m365 in config.yaml"
        return 0
    fi
    yaml_merge <<<"$(_assistant_m365_fragment "$@")"
}

# A world that is switched off stays in config.yaml as enabled: false — the
# merge cannot delete keys, and the agent treats that flag as "not there".
_assistant_disable() {
    local name=$1
    [[ -f $(yaml_config_path) ]] || { log_skip "assistant ${name} disabled; no config.yaml yet"; return 0; }
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] mark mcp_servers.${name} enabled: false"
        return 0
    fi
    yaml_merge <<EOF
mcp_servers:
  ${name}:
    enabled: false
EOF
}

# The delegated scopes for the assistant are declared and consented by the
# azure module together with the mail relay's — one consent covers every
# consumer of the app registration. See _az_delegated_scopes_ensure.
# ---------------------------------------------------------------------------
# The one-time sign-in, and the check that the token is the right account's.
# ---------------------------------------------------------------------------
_assistant_m365_signin() {
    local tenant=$1 client=$2 account=$3 tok
    tok=$(assistant_m365_token_file)

    if [[ $DRY_RUN == true ]]; then
        if [[ -s $tok ]]; then log_info "[dry-run] token present at ${tok}; would verify it"
        else log_info "[dry-run] no token at ${tok}; would run the device-code sign-in as ${account}"; fi
        return 0
    fi

    local ctl; ctl=$(assistant_m365ctl)
    if ! sudo -u "$SERVICE_USER" "$ctl" status >/dev/null 2>&1; then
        log_info "  no usable M365 token; starting the device-code sign-in (once)"
        log_info "  Sign in AS ${account} in a PRIVATE browser window; the code appears below."
        if ! sudo -u "$SERVICE_USER" "$ctl" login "$ASSISTANT_LOGIN_TIMEOUT"; then
            defer_failure "assistant: the M365 sign-in for ${account} did not complete; run the installer again and enter the code"
            return 0
        fi
        mark_changed
    fi

    local status
    if status=$(sudo -u "$SERVICE_USER" "$ctl" status 2>&1); then
        log_ok "m365 token verified: $(jq -r '.account' <<<"$status" 2>/dev/null || printf '%s' "$status")"
    else
        defer_failure "assistant: the M365 token check failed: ${status}"
    fi
}

assistant_uninstall() {
    run rm -rf "$ASSISTANT_VENV" "$ASSISTANT_LIB_DIR" "$ASSISTANT_STATE_DIR"
}

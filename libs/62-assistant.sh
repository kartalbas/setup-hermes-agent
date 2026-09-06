# shellcheck shell=bash
#
# The assistant — the agent's hands in Microsoft 365 (and, in its own part,
# Google): MCP servers from bot/mcp/, installed into their own virtualenv and
# registered in the agent's config.yaml under mcp_servers.
#
# The servers' commands run as the service account through runuser, never a
# nested sudo: this host's sudo (sudo-rs, `Defaults use_pty`) gives every sudo
# its own pseudo-terminal, and a sign-in that reads the operator's paste from
# /dev/tty inside sudo-inside-sudo waited on a terminal nobody typed into —
# and Ctrl-C never reached it (2026-09-07).
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
    local any=false
    is_true "${ASSISTANT_M365_ENABLED:-false}" && any=true
    is_true "${ASSISTANT_GOOGLE_ENABLED:-false}" && any=true
    is_true "${ASSISTANT_GITHUB_ENABLED:-false}" && any=true

    if [[ $any != true ]]; then
        _assistant_disable_all m365
        _assistant_disable_all google
        _assistant_disable_all github
        return 0
    fi

    _assistant_venv
    _assistant_install_code
    if is_true "${ASSISTANT_M365_ENABLED:-false}"; then _assistant_m365; else _assistant_disable_all m365; fi
    if is_true "${ASSISTANT_GOOGLE_ENABLED:-false}"; then _assistant_google; else _assistant_disable_all google; fi
    if is_true "${ASSISTANT_GITHUB_ENABLED:-false}"; then _assistant_github; else _assistant_disable_all github; fi
    (( $(bot_count) == 0 )) && converge_unit "${SERVICE_NAME}.service" "$before"
    _assistant_restart_stale
    return 0
}

# The MCP servers are children of the gateway, started with the server code
# and env files of that moment. New code or a rewritten env file therefore
# needs the bots that use them restarted — which an unchanged config.yaml
# never triggers. A stamp per bot records what its servers were last started
# with; a bot already restarted in this run only gets the stamp.
_assistant_code_stamp() {         # -> short hash over the installed servers and their env files
    local f files=()
    for f in "$ASSISTANT_LIB_DIR"/*.py "$(assistant_m365_env_file)" "$(assistant_google_env_file)" "$(assistant_github_env_file)"; do
        [[ -f $f ]] && files+=("$f")
    done
    (( ${#files[@]} > 0 )) || { printf 'none'; return 0; }
    cat "${files[@]}" | sha256sum | cut -c1-16
}

_assistant_restart_stale() {
    (( $(bot_count) > 0 )) || return 0
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would restart bots whose MCP servers were started with older code or environment"
        return 0
    fi
    local stamp key stamp_file; stamp=$(_assistant_code_stamp)
    while IFS= read -r key; do
        [[ -n $key && -n $(bot_field "$key" MCP) ]] || continue
        bot_context "$key"
        stamp_file="${ASSISTANT_STATE_DIR}/started-${key}.stamp"
        if [[ $(cat "$stamp_file" 2>/dev/null) == "$stamp" ]]; then
            log_skip "${BOT_SERVICE}: MCP servers run the installed code"
        else
            if unit_restarted_this_run "${BOT_SERVICE}.service"; then
                log_skip "${BOT_SERVICE} restarted in this run already"
            else
                log_info "restarting ${BOT_SERVICE}: its MCP servers were started with older code or environment"
                run systemctl restart "${BOT_SERVICE}.service"   # gated on the stamp mismatch above
                mark_changed
            fi
            write_file "$stamp_file" 0644 <<<"$stamp"
        fi
        bot_context_end
    done < <(bots)
}

# enabled: false in every profile (or the default one).
_assistant_disable_all() {
    local name=$1 key
    if (( $(bot_count) == 0 )); then _assistant_disable "$name"; return 0; fi
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"; _assistant_disable "$name"; bot_context_end
    done < <(bots)
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
    [[ -f ${src}/assistant_common.py && -f ${src}/m365_assistant.py && -f ${src}/google_assistant.py ]] ||
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
    _assistant_m365_read_mailboxes
    _assistant_m365_folder "$tenant" "$client" "$account"
    _assistant_m365_mail_rules
    _assistant_m365_register_all "$tenant" "$client" "$account"
}

# The operator's mailboxes the assistant may read. Two grants make one
# readable and the run can do only one of them: the Mail.Read.Shared scope on
# the app (azure module, with the other scopes). The other is Exchange's own
# mailbox delegation, which Graph does not expose — so the run checks, and
# when the check fails it names the click path instead of pretending.
_assistant_m365_read_mailboxes() {
    [[ -n ${ASSISTANT_M365_READ_MAILBOXES:-} ]] || return 0
    local IFS=$' ,\t\n' mb out
    for mb in $ASSISTANT_M365_READ_MAILBOXES; do
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] would check that ${ASSISTANT_M365_ACCOUNT} can read the mailbox ${mb}"
            continue
        fi
        [[ -s $(assistant_m365_token_file) ]] || { log_skip "no token yet; mailbox checks after the sign-in"; return 0; }
        if out=$(runuser -u "$SERVICE_USER" -- "$(assistant_m365ctl)" check-mailbox "$mb" 2>&1); then
            log_ok "mailbox readable  ${mb} (inbox: $(jq -r '.inbox_total' <<<"$out" 2>/dev/null) messages)"
        else
            log_error "the assistant cannot read the mailbox ${mb}: $(jq -r '.reason // .' <<<"$out" 2>/dev/null || printf '%s' "$out")"
            log_error "  Two grants make a mailbox readable. Mail.Read.Shared on the app is declared and consented by the run;"
            log_error "  the mailbox delegation is Exchange's own and not in Graph — once, signed in as a tenant ADMIN (not as ${ASSISTANT_M365_ACCOUNT}):"
            log_error "    https://admin.exchange.microsoft.com/#/mailboxes -> ${mb} -> Delegation -> Read and manage (Full Access) -> Add -> ${ASSISTANT_M365_ACCOUNT}"
            log_error "  Exchange applies it within about an hour; then re-run the installer."
            defer_failure "assistant: the mailbox ${mb} is not readable by ${ASSISTANT_M365_ACCOUNT} yet"
        fi
    done
}

# One mailbox, several bots: Exchange sorts mail per alias into a folder the
# bot polls. Rules and folders are created in the agent's mailbox over Graph.
_assistant_m365_mail_rules() {
    (( $(bot_count) > 0 )) || return 0
    local key alias folder out
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_has_channel "$key" email || continue
        alias=$(bot_field "$key" MAIL_ALIAS); folder=$(bot_field "$key" MAIL_FOLDER)
        [[ -n $alias && $folder != INBOX ]] || continue
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] mail rule: ${alias} -> folder ${folder} (bot ${key})"
            continue
        fi
        [[ -s $(assistant_m365_token_file) ]] || { log_skip "no token yet; mail rules after the sign-in"; return 0; }
        if out=$(runuser -u "$SERVICE_USER" -- "$(assistant_m365ctl)" ensure-mail-rule "$alias" "$folder" 2>&1); then
            if [[ $(jq -r '.rule_created or .folder_created' <<<"$out" 2>/dev/null) == true ]]; then
                mark_changed; log_ok "mail rule: ${alias} -> ${folder} (bot ${key})"
            else
                log_skip "mail rule present: ${alias} -> ${folder}"
            fi
        else
            defer_failure "assistant: could not create the mail rule ${alias} -> ${folder}: ${out}"
        fi
    done < <(bots)
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
    if out=$(runuser -u "$SERVICE_USER" -- "$(assistant_m365ctl)" \
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
    printf 'M365_TENANT_ID=%s\nM365_CLIENT_ID=%s\nM365_ACCOUNT=%s\nM365_TOKEN_FILE=%s\nM365_TIMEZONE=%s\nM365_SCOPES=%s\nM365_READ_MAILBOXES=%s\n' \
        "$1" "$2" "$3" "$(assistant_m365_token_file)" "$ASSISTANT_M365_TIMEZONE" "$ASSISTANT_M365_SCOPES" "${ASSISTANT_M365_READ_MAILBOXES:-}"
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
#   m365ctl status | login | ensure-folder PATH [EMAILS [read|write]] | ensure-mail-rule ALIAS FOLDER | check-mailbox ADDRESS | tools | serve
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
    if ! runuser -u "$SERVICE_USER" -- "$ctl" status >/dev/null 2>&1; then
        log_info "  no usable M365 token; starting the device-code sign-in (once)"
        log_info "  Sign in AS ${account} in a PRIVATE browser window; the code appears below."
        if ! runuser -u "$SERVICE_USER" -- "$ctl" login "$ASSISTANT_LOGIN_TIMEOUT"; then
            defer_failure "assistant: the M365 sign-in for ${account} did not complete; run the installer again and enter the code"
            return 0
        fi
        mark_changed
    fi

    local status
    if status=$(runuser -u "$SERVICE_USER" -- "$ctl" status 2>&1); then
        log_ok "m365 token verified: $(jq -r '.account' <<<"$status" 2>/dev/null || printf '%s' "$status")"
    else
        defer_failure "assistant: the M365 token check failed: ${status}"
    fi
}


# ---------------------------------------------------------------------------
# Google — the private account
#
# Same shape as Microsoft 365: env file, a `googlectl` wrapper, a one-time
# sign-in, registration in the profiles that list "google". The sign-in is a
# paste-back (Google's device flow does not cover Gmail/Calendar/Drive), so it
# needs a terminal: run interactively it happens in the run, otherwise the run
# names the command and carries on.
# ---------------------------------------------------------------------------
assistant_google_token_file() { printf '%s/google.token' "$ASSISTANT_STATE_DIR"; }
assistant_google_env_file()   { printf '%s/google.env' "$ASSISTANT_STATE_DIR"; }
assistant_googlectl()         { printf '%s/googlectl' "$ASSISTANT_LIB_DIR"; }

_assistant_google() {
    local account=$ASSISTANT_GOOGLE_ACCOUNT
    if ! secret_nonempty "$ASSISTANT_GOOGLE_CLIENT_ID_VAR" || ! secret_nonempty "$ASSISTANT_GOOGLE_CLIENT_SECRET_VAR"; then
        log_skip "google assistant waits for the OAuth client (see the google module above)"
        _assistant_disable_all google
        return 0
    fi
    log_info "assistant      google as ${account}"
    _assistant_google_wrapper
    _assistant_google_signin
    _assistant_google_signin_readers
    _assistant_google_register_all
}

_assistant_google_env_lines() {
    printf 'GOOGLE_CLIENT_ID=%s\nGOOGLE_CLIENT_SECRET=%s\nGOOGLE_ACCOUNT=%s\nGOOGLE_TOKEN_FILE=%s\nGOOGLE_TIMEZONE=%s\nGOOGLE_SCOPES=%s\nGOOGLE_READ_ACCOUNTS=%s\nGOOGLE_READ_SCOPES=%s\n' \
        "$(secret_get "$ASSISTANT_GOOGLE_CLIENT_ID_VAR")" "$(secret_get "$ASSISTANT_GOOGLE_CLIENT_SECRET_VAR")" \
        "$ASSISTANT_GOOGLE_ACCOUNT" "$(assistant_google_token_file)" "$ASSISTANT_GOOGLE_TIMEZONE" "$ASSISTANT_GOOGLE_SCOPES" \
        "${ASSISTANT_GOOGLE_READ_ACCOUNTS:-}" "$ASSISTANT_GOOGLE_READ_SCOPES"
}

_assistant_google_wrapper() {
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write $(assistant_google_env_file) and $(assistant_googlectl)"
        return 0
    fi
    # The client secret is in here, hence 0600 and the service account only.
    write_file "$(assistant_google_env_file)" 0600 "${SERVICE_USER}:${SERVICE_GROUP}" \
        <<<"$(_assistant_google_env_lines | sed "s/^\([A-Z_0-9]*\)=\(.*\)$/\1='\2'/")"
    write_file "$(assistant_googlectl)" 0755 <<EOF
#!/usr/bin/env bash
# Runs the Google assistant's commands with its configured environment:
#   googlectl status [ACCOUNT] | login [ACCOUNT] | tools | serve
set -euo pipefail
set -a; . "$(assistant_google_env_file)"; set +a
exec "$(assistant_python)" "${ASSISTANT_LIB_DIR}/google_assistant.py" "\$@"
EOF
}

# The MCP entry reads the env file too, so the client secret is not written
# into config.yaml.
_assistant_google_fragment() {
    cat <<EOF
mcp_servers:
  google:
    enabled: true
    command: "$(assistant_googlectl)"
    args: ["serve"]
    timeout: 120
    connect_timeout: 30
EOF
}

_assistant_google_register_all() {
    if (( $(bot_count) == 0 )); then
        [[ $DRY_RUN == true ]] && { log_info "[dry-run] register mcp_servers.google"; return 0; }
        yaml_merge <<<"$(_assistant_google_fragment)"
        return 0
    fi
    local key before
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"
        before=$CHANGE_COUNT
        if bot_has_mcp "$key" google; then
            if [[ $DRY_RUN == true ]]; then log_info "[dry-run] register mcp_servers.google in ${BOT_KEY}"
            else yaml_merge <<<"$(_assistant_google_fragment)"; fi
        else
            _assistant_disable google
        fi
        converge_unit "${BOT_SERVICE}.service" "$before"
        bot_context_end
    done < <(bots)
}

_assistant_google_signin() {
    local ctl; ctl=$(assistant_googlectl)
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would verify the Google token, or ask for the one-time sign-in"
        return 0
    fi
    if runuser -u "$SERVICE_USER" -- "$ctl" status >/dev/null 2>&1; then
        log_ok "google token verified: $(runuser -u "$SERVICE_USER" -- "$ctl" status 2>/dev/null | jq -r '.account')"
        return 0
    fi
    if has_tty; then
        log_info "  no usable Google token; the sign-in needs you — a URL to open AS ${ASSISTANT_GOOGLE_ACCOUNT}, and the address you land on pasted back"
        # shellcheck disable=SC2024  # the redirect is the point: the paste-back reads the operator's terminal
        if runuser -u "$SERVICE_USER" -- "$ctl" login </dev/tty; then
            mark_changed
            log_ok "google token stored for ${ASSISTANT_GOOGLE_ACCOUNT}"
            return 0
        fi
        defer_failure "assistant: the Google sign-in for ${ASSISTANT_GOOGLE_ACCOUNT} did not complete"
        return 0
    fi
    log_error "no Google token yet, and this run has no terminal for the paste-back sign-in. Run once, then re-run the installer:"
    log_error "    sudo -u ${SERVICE_USER} ${ctl} login        (sign in AS ${ASSISTANT_GOOGLE_ACCOUNT})"
    defer_failure "assistant: Google sign-in pending for ${ASSISTANT_GOOGLE_ACCOUNT}"
}

# The operator's own Gmail accounts the assistant may read: one token each,
# from a sign-in AS that account with the read-only scopes. Same paste-back as
# above; the token file is named after the account.
_assistant_google_signin_readers() {
    [[ -n ${ASSISTANT_GOOGLE_READ_ACCOUNTS:-} ]] || return 0
    local IFS=$' ,\t\n' acct ctl; ctl=$(assistant_googlectl)
    for acct in $ASSISTANT_GOOGLE_READ_ACCOUNTS; do
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] would verify the read-only Gmail token for ${acct}, or ask for its sign-in"
            continue
        fi
        if runuser -u "$SERVICE_USER" -- "$ctl" status "$acct" >/dev/null 2>&1; then
            log_ok "google read token verified: ${acct}"
            continue
        fi
        if has_tty; then
            log_info "  no token for ${acct}; the sign-in needs you — open the URL AS ${acct} (read-only Gmail), paste the address you land on"
            # shellcheck disable=SC2024  # the redirect is the point: the paste-back reads the operator's terminal
            if runuser -u "$SERVICE_USER" -- "$ctl" login "$acct" </dev/tty; then
                mark_changed
                log_ok "google read token stored for ${acct}"
                continue
            fi
            defer_failure "assistant: the Google sign-in for ${acct} did not complete"
            continue
        fi
        log_error "no Google token for ${acct}, and this run has no terminal for the paste-back sign-in. Run once, then re-run the installer:"
        log_error "    sudo -u ${SERVICE_USER} ${ctl} login ${acct}        (sign in AS ${acct})"
        defer_failure "assistant: Google sign-in pending for ${acct}"
    done
}

assistant_uninstall() {
    run rm -rf "$ASSISTANT_VENV" "$ASSISTANT_LIB_DIR" "$ASSISTANT_STATE_DIR"
}

# ---------------------------------------------------------------------------
# GitHub — the official github/github-mcp-server, a Go binary from its release,
# checksum-verified, pinned by ASSISTANT_GITHUB_MCP_VERSION. It talks to GitHub
# with a personal access token from the secrets file, handed over through an
# env file the wrapper sources — the token never lands in config.yaml.
# ---------------------------------------------------------------------------
assistant_github_binary()   { printf '%s/github-mcp-server' "$ASSISTANT_LIB_DIR"; }
assistant_github_env_file() { printf '%s/github.env' "$ASSISTANT_STATE_DIR"; }
assistant_githubctl()       { printf '%s/githubctl' "$ASSISTANT_LIB_DIR"; }

_assistant_github() {
    if ! secret_nonempty "$ASSISTANT_GITHUB_TOKEN_VAR"; then
        log_error "the GitHub assistant needs a personal access token as ${ASSISTANT_GITHUB_TOKEN_VAR} in the secrets file"
        log_error "  GitHub -> Settings -> Developer settings -> Personal access tokens (fine-grained: the repositories"
        log_error "  the bot may see; permissions per toolset: contents, issues, pull requests, actions, security events)"
        defer_failure "assistant: ${ASSISTANT_GITHUB_TOKEN_VAR} missing; the GitHub side waits for it"
        _assistant_disable_all github
        return 0
    fi
    log_info "assistant      github (mcp server ${ASSISTANT_GITHUB_MCP_VERSION})"
    _assistant_github_binary
    _assistant_github_wrapper
    _assistant_github_verify
    _assistant_github_register_all
}

# github-mcp-server_Linux_<arch>.tar.gz plus the release's checksums file.
_assistant_github_arch() {
    case $(uname -m) in
        x86_64) printf 'x86_64' ;; aarch64|arm64) printf 'arm64' ;; i?86) printf 'i386' ;;
        *) die "no github-mcp-server build for $(uname -m)" ;;
    esac
}

_assistant_github_binary() {
    local bin; bin=$(assistant_github_binary)
    local v=$ASSISTANT_GITHUB_MCP_VERSION
    if [[ -x $bin ]] && "$bin" --version 2>/dev/null | grep -q "$v"; then
        log_skip "github-mcp-server ${v} present"
        return 0
    fi
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] download github-mcp-server ${v} for $(_assistant_github_arch), verify checksum, install to ${bin}"
        return 0
    fi
    local base="https://github.com/github/github-mcp-server/releases/download/v${v}"
    local asset; asset="github-mcp-server_Linux_$(_assistant_github_arch).tar.gz"
    local dir; dir=$(mktemp -d)
    log_info "  downloading ${asset}"
    fetch -o "${dir}/${asset}" "${base}/${asset}" || { rm -rf "$dir"; die "could not download ${asset}"; }
    fetch -o "${dir}/checksums.txt" "${base}/github-mcp-server_${v}_checksums.txt" || { rm -rf "$dir"; die "could not download the checksums file"; }
    (cd "$dir" && grep " ${asset}\$" checksums.txt | sha256sum -c --quiet -) ||
        { rm -rf "$dir"; die "checksum mismatch for ${asset}"; }
    tar -xzf "${dir}/${asset}" -C "$dir" github-mcp-server
    install -m 0755 "${dir}/github-mcp-server" "$bin"
    rm -rf "$dir"
    mark_changed
    log_ok "github-mcp-server ${v} installed"
}

_assistant_github_env_lines() {
    printf 'GITHUB_PERSONAL_ACCESS_TOKEN=%s\nGITHUB_TOOLSETS=%s\nGITHUB_READ_ONLY=%s\n' \
        "$(secret_get "$ASSISTANT_GITHUB_TOKEN_VAR")" "$ASSISTANT_GITHUB_TOOLSETS" \
        "$(is_true "$ASSISTANT_GITHUB_READ_ONLY" && printf 1 || printf 0)"
}

_assistant_github_wrapper() {
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write $(assistant_github_env_file) and $(assistant_githubctl)"
        return 0
    fi
    write_file "$(assistant_github_env_file)" 0600 "${SERVICE_USER}:${SERVICE_GROUP}" \
        <<<"$(_assistant_github_env_lines | sed "s/^\([A-Z_0-9]*\)=\(.*\)$/\1='\2'/")"
    write_file "$(assistant_githubctl)" 0755 <<EOF
#!/usr/bin/env bash
# Runs the GitHub MCP server with the operator's token and toolsets:
#   githubctl stdio          (what the gateway runs)
#   githubctl --version
set -euo pipefail
set -a; . "$(assistant_github_env_file)"; set +a
case \$GITHUB_READ_ONLY in 1) set -- "\$@" --read-only ;; esac
exec "$(assistant_github_binary)" "\$@"
EOF
}

_assistant_github_verify() {
    [[ $DRY_RUN == true ]] && return 0
    local out
    out=$(runuser -u "$SERVICE_USER" -- "$(assistant_githubctl)" --version 2>&1) ||
        die "github-mcp-server does not start: ${out}"
    log_ok "github mcp     ${out} (toolsets: ${ASSISTANT_GITHUB_TOOLSETS})"
}

_assistant_github_fragment() {
    cat <<EOF
mcp_servers:
  github:
    enabled: true
    command: "$(assistant_githubctl)"
    args: ["stdio"]
    timeout: 120
    connect_timeout: 30
EOF
}

_assistant_github_register_all() {
    if (( $(bot_count) == 0 )); then
        [[ $DRY_RUN == true ]] && { log_info "[dry-run] register mcp_servers.github"; return 0; }
        yaml_merge <<<"$(_assistant_github_fragment)"
        return 0
    fi
    local key before
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"
        before=$CHANGE_COUNT
        if bot_has_mcp "$key" github; then
            if [[ $DRY_RUN == true ]]; then log_info "[dry-run] register mcp_servers.github in ${BOT_KEY}"
            else yaml_merge <<<"$(_assistant_github_fragment)"; fi
        else
            _assistant_disable github
        fi
        converge_unit "${BOT_SERVICE}.service" "$before"
        bot_context_end
    done < <(bots)
}

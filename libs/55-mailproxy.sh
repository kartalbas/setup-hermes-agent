# shellcheck shell=bash
#
# A local IMAP/SMTP relay that speaks OAuth outward and plain login inward.
#
# WHY IT EXISTS
# -------------
# The corporate mail server offers no password authentication at all. Asked for
# its capabilities it answers `AUTH=XOAUTH2 LOGINDISABLED`, and a login attempt
# returns "Basic authentication is disabled." — so an app password cannot help,
# because an app password *is* basic authentication.
#
# The adapter, for its part, speaks only password authentication, and documents
# pointing IMAP and SMTP at 127.0.0.1 for exactly this situation. The relay sits
# between: it holds the OAuth credentials and presents an ordinary mailbox on
# loopback.
#
# The device flow is the default. The alternative — client credentials — needs
# admin consent and a service principal scoped to the mailbox through Exchange
# PowerShell; the device flow needs one app registration and one sign-in, and
# the vendor documents it as the better fit for headless systems. It costs a
# refresh token that can eventually be revoked, at which point the sign-in is
# repeated; that is a fair trade for a great deal less setup.

mailproxy_apply() {
    if ! is_true "${MAILPROXY_ENABLED:-false}"; then
        log_skip "mail relay disabled (MAILPROXY_ENABLED=false)"
        return 0
    fi

    log_step "Mail relay"
    require_root "installing the relay service"

    _mailproxy_install
    local before=$CHANGE_COUNT
    _mailproxy_ensure_cert
    _mailproxy_write_config
    _mailproxy_write_unit
    converge_unit "$(mailproxy_unit_name).service" "$before"
    _mailproxy_verify
}

mailproxy_unit_name()   { printf '%s-mailproxy' "$SERVICE_NAME"; }
mailproxy_config_path() { printf '%s/emailproxy.config' "${MAILPROXY_STATE_DIR}"; }
mailproxy_python()      { printf '%s/bin/python' "${MAILPROXY_VENV}"; }

# ---------------------------------------------------------------------------
# Installation
#
# Its own virtual environment: this is a Python application with dependencies of
# its own, and mixing them into the system interpreter is how a distribution
# upgrade breaks a mail relay.
# ---------------------------------------------------------------------------
_mailproxy_install() {
    local py; py=$(mailproxy_python)

    if [[ $DRY_RUN != true ]] && [[ -x $py ]] && "$py" -c 'import emailproxy' >/dev/null 2>&1; then
        log_skip "relay already installed at ${MAILPROXY_VENV}"
        return 0
    fi

    require_cmd python3
    ensure_dir "$(dirname "$MAILPROXY_VENV")" 0755
    ensure_dir "$MAILPROXY_STATE_DIR" 0700 "${SERVICE_USER}:${SERVICE_GROUP}"

    log_info "installing the relay into ${MAILPROXY_VENV}"
    run python3 -m venv "$MAILPROXY_VENV"
    # No GUI extra: there is no display here, and the extra pulls a toolkit.
    run "$(mailproxy_python)" -m pip install --quiet --upgrade pip
    run "$(mailproxy_python)" -m pip install --quiet emailproxy
    run chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$MAILPROXY_VENV"
    mark_changed
}

# ---------------------------------------------------------------------------
# Configuration
#
# Written whole rather than merged: unlike the agent's own files, this one has
# no other author. The relay does append to it — it stores tokens under the
# account entry — so the token block is preserved across rewrites.
# ---------------------------------------------------------------------------
# What of this file is ours to compare.
#
# Two things are not: the token block, which the relay refreshes on its own
# schedule, and the comments — the relay rewrites the file with configparser
# whenever it stores a token, and configparser discards comments. Our generated
# text has a header; the file on disk never does after the first sign-in. So a
# byte comparison can never match, and the run rewrote the file every time,
# set CHANGED, and restarted the gateway "to pick up the new configuration".
_mailproxy_significant() {
    grep -vE '^[[:space:]]*(#|$)' \
        | grep -vE '^(access_token|refresh_token|token_salt|token_iterations|access_token_expiry|last_activity)'
}

# The pinned agent connects to IMAP with imaplib.IMAP4_SSL and no alternative:
#
#   imap = imaplib.IMAP4_SSL(self._imap_host, self._imap_port, timeout=30)
#
# There is no imap_security in this release — that landed on main and is in no
# tag yet. So the relay cannot offer a plaintext loopback socket, however
# reasonable that is over loopback; it has to speak TLS, and the certificate has
# to satisfy a default SSL context, which verifies against the system store and
# checks the hostname.
#
# Hence: a self-signed certificate carrying IP:127.0.0.1, installed into the
# system trust store. It is generated once and kept — replacing it on every run
# would invalidate a live connection for nothing.
_mailproxy_ensure_cert() {
    local dir=$MAILPROXY_STATE_DIR
    local crt="${dir}/relay.crt" key="${dir}/relay.key"
    local anchor="/usr/local/share/ca-certificates/hermes-mail-relay.crt"

    MAILPROXY_CERT=$crt
    MAILPROXY_KEY=$key

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] ensure a loopback TLS certificate at ${crt}, trusted system-wide"
        return 0
    fi

    if [[ ! -s $crt || ! -s $key ]]; then
        require_cmd openssl
        log_info "generating a loopback certificate for the mail relay"
        run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$key" -out "$crt" \
            -subj "/CN=hermes-mail-relay" \
            -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
        run chmod 0600 "$key"
        run chmod 0644 "$crt"
        [[ -n ${SERVICE_USER:-} ]] && run chown "${SERVICE_USER}:${SERVICE_GROUP}" "$key" "$crt"
        mark_changed
    fi

    # The agent verifies against the system store, so the certificate has to be
    # in it. Without this the connection fails with a certificate error rather
    # than a protocol one, which reads like a different problem entirely.
    if ! cmp -s "$crt" "$anchor" 2>/dev/null; then
        ensure_dir "$(dirname "$anchor")" 0755
        run install -m 0644 "$crt" "$anchor"
        run update-ca-certificates
        mark_changed
    fi
}

_mailproxy_write_config() {
    local cfg address tenant client_id secret flow scope
    cfg=$(mailproxy_config_path)
    address=${CHANNEL_EMAIL_WORK_ADDRESS:?the work mailbox address is not configured}
    tenant=$(secret_require "$MAILPROXY_TENANT_ID_VAR" "the mail relay")
    client_id=$(secret_require "$MAILPROXY_CLIENT_ID_VAR" "the mail relay")
    flow=${MAILPROXY_FLOW:-device}

    case $flow in
        device)
            # Names from MAILPROXY_SCOPES (the azure module declares and
            # consents the same names), as Exchange resource URLs.
            local IFS=$' \t\n' n
            scope=""
            for n in $MAILPROXY_SCOPES; do scope+="https://outlook.office.com/${n} "; done
            scope+="offline_access"
            ;;
        client_credentials)
            # App-only: one scope, and the tenant must have consented.
            scope="https://outlook.office365.com/.default"
            secret=$(secret_require "$MAILPROXY_CLIENT_SECRET_VAR" "the client-credentials flow")
            ;;
        *) die "MAILPROXY_FLOW must be 'device' or 'client_credentials', got '${flow}'" ;;
    esac

    # An existing token block is kept: losing it means signing in again for no
    # reason, which on a headless host is a genuine interruption.
    local existing=""
    if [[ $DRY_RUN != true && -f $cfg ]]; then
        existing=$(sed -n '/^\(access_token\|refresh_token\|token_salt\|token_iterations\|access_token_expiry\|last_activity\)/p' "$cfg")
    fi

    local body
    body="# Managed by setup-hermes-agent. Tokens below are written by the relay.
#
# The absence of permission_url is what selects the non-interactive flow; see
# the vendor's sample configuration.
[${address}]
token_url = https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token"
    [[ $flow == device ]] && body+="
permission_url = https://login.microsoftonline.com/${tenant}/oauth2/v2.0/devicecode"
    body+="
oauth2_scope = ${scope}
oauth2_flow = ${flow}
client_id = ${client_id}"
    [[ $flow == client_credentials ]] && body+="
client_secret = ${secret}"

    # The server sections are what emailproxy actually looks for: it matches
    # section names against ^(IMAP|POP|SMTP)-(\d+)$ and the number IS the local
    # port. Without them it reports "No server configuration(s) found" and exits,
    # which reads like a broken account section rather than a missing one.
    #
    # The local listeners are plaintext — no certificate is configured and the
    # hop is loopback. `starttls` applies to the connection the relay makes
    # onward, and only to SMTP; IMAP is implicit TLS.
    local up_imap up_smtp
    up_imap=${CHANNEL_EMAIL_WORK_IMAP_HOST:?the work mailbox IMAP host is not configured}
    up_smtp=${CHANNEL_EMAIL_WORK_SMTP_HOST:?the work mailbox SMTP host is not configured}

    # The preserved tokens belong to the ACCOUNT section, so they go in before
    # the server sections open. Appended at the end — as they were — they land
    # under whichever section happens to be last, and the relay then cannot find
    # the account's credentials at all.
    [[ -n $existing ]] && body+="
${existing}"

    body+="

[IMAP-${MAILPROXY_IMAP_PORT}]
local_address = ${MAILPROXY_LISTEN}
local_certificate_path = ${MAILPROXY_CERT}
local_key_path = ${MAILPROXY_KEY}
server_address = ${up_imap}
server_port = ${CHANNEL_EMAIL_IMAP_PORT}

[SMTP-${MAILPROXY_SMTP_PORT}]
local_address = ${MAILPROXY_LISTEN}
local_certificate_path = ${MAILPROXY_CERT}
local_key_path = ${MAILPROXY_KEY}
local_starttls = True
server_address = ${up_smtp}
server_port = ${CHANNEL_EMAIL_SMTP_PORT}
starttls = $( [[ ${CHANNEL_EMAIL_SMTP_PORT} == 465 ]] && printf False || printf True )
"


    # Compare only what WE own. The relay writes its own lines back into this
    # file — refreshed access tokens, expiry, last_activity — so the token block
    # differs on every run by design. Treating that as our change rewrote the
    # file, set CHANGED, and the channels module then restarted the gateway to
    # "pick up the new configuration": a live agent interrupted because a
    # timestamp moved.
    if [[ $DRY_RUN != true && -f $cfg ]]; then
        local ours theirs
        ours=$(printf '%s\n' "$body" | _mailproxy_significant)
        theirs=$(_mailproxy_significant <"$cfg")
        if [[ $ours == "$theirs" ]]; then
            log_skip "unchanged: ${cfg}"
            return 0
        fi
        # "changed" without saying what changed is how a rewrite loop hides.
        # Capture first: `diff | head` sends SIGPIPE to diff when head stops
        # early, and under errexit the diagnostic then fails louder than the
        # thing it was meant to explain.
        local report
        report=$(diff <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") 2>/dev/null | head -12 || true)
        if [[ -n $report ]]; then
            log_debug "relay config differs:"
            while IFS= read -r d; do log_debug "  ${d}"; done <<<"$report"
        fi
    fi

    # Stop it first. The relay keeps its configuration in memory and writes it
    # back when it shuts down, so a write while it runs is overwritten moments
    # later by its own copy — the file ends up in configparser's key order with
    # our additions missing, which looks like the write never happened. The same
    # behaviour resurrected a deleted token file earlier in this module's life.
    local unit; unit=$(mailproxy_unit_name)
    if [[ $DRY_RUN != true ]] && systemctl is-active --quiet "${unit}.service" 2>/dev/null; then
        log_info "stopping the relay to rewrite its configuration"
        run systemctl stop "${unit}.service"
    fi

    write_file "$cfg" 0600 "${SERVICE_USER}:${SERVICE_GROUP}" <<<"$body"
}

_mailproxy_write_unit() {
    local unit py cfg
    unit=$(mailproxy_unit_name)
    py=$(mailproxy_python)
    cfg=$(mailproxy_config_path)

    write_file "/etc/systemd/system/${unit}.service" 0644 <<EOF
# Managed by setup-hermes-agent.
[Unit]
Description=OAuth mail relay for ${CHANNEL_EMAIL_WORK_ADDRESS}
After=network-online.target
Wants=network-online.target
# The gateway polls through this; starting the other way round means its first
# poll meets a closed port.
Before=${SERVICE_NAME}.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${MAILPROXY_STATE_DIR}
# --no-gui because there is no display; --external-auth so a sign-in prints a
# URL to the journal instead of waiting for a browser that will never open.
ExecStart=${py} -m emailproxy --no-gui --external-auth --config-file ${cfg}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${unit}

NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
}

_mailproxy_verify() {
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] would verify the relay is listening"; return 0; }

    local unit waited=0
    unit=$(mailproxy_unit_name)
    while (( waited < 30 )); do
        if ss -H -ltn "sport = :${MAILPROXY_IMAP_PORT}" 2>/dev/null | grep -q .; then
            log_ok "relay listening on ${MAILPROXY_LISTEN}:${MAILPROXY_IMAP_PORT} (imap) and :${MAILPROXY_SMTP_PORT} (smtp)"
            _mailproxy_report_signin
            return 0
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done

    log_error "the relay is not listening after 30s; last 30 journal lines:"
    journalctl -u "${unit}.service" -n 30 --no-pager >&2 || true
    die "the mail relay failed to start"
}

# The sign-in is the one step nobody can automate. It happens once: the relay
# stores a refresh token and renews it by itself from then on.
_mailproxy_report_signin() {
    local unit; unit=$(mailproxy_unit_name)
    grep -q '^refresh_token' "$(mailproxy_config_path)" 2>/dev/null && {
        log_ok "the relay holds a refresh token; no sign-in needed"
        return 0
    }
    {
        printf '\n'
        printf '  The relay is running but not yet authorised.\n\n'
        printf '  It prints a sign-in URL and code the first time the agent connects.\n'
        printf '  Watch for it, open the URL on your own machine, and sign in as %s:\n\n' \
               "${CHANNEL_EMAIL_WORK_ADDRESS}"
        printf '    journalctl -u %s -f\n\n' "$unit"
        printf '  It happens once. Afterwards the relay renews its own token.\n\n'
    } >&2
}

# ---------------------------------------------------------------------------
# A stale access token.
#
# The relay caches its access token for an hour. When the app's consent changed
# in the meantime (the azure module declaring and consenting scopes), the token
# it holds no longer carries the rights Exchange checks, and every login is
# answered "AUTHENTICATE failed" although the refresh token is perfectly good.
# Dropping the cached access token makes the relay fetch one with the current
# consent. The relay rewrites its file on shutdown, so it is stopped first.
# ---------------------------------------------------------------------------
mailproxy_force_refresh() {
    local cfg; cfg=$(mailproxy_config_path)
    [[ -f $cfg ]] || return 1
    grep -q '^refresh_token' "$cfg" || return 1
    log_info "  relay: dropping the cached access token so it is renewed under the current consent"
    run systemctl stop "$(mailproxy_unit_name)" || true
    run sed -i -E '/^(access_token|access_token_expiry) *=/d' "$cfg"
    run systemctl start "$(mailproxy_unit_name)"
    sleep 3
    mark_changed
}

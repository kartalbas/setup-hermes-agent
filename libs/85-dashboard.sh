# shellcheck shell=bash
#
# The agent's web dashboard, and reaching it from another machine.
#
# The dashboard displays and edits configuration, which includes API keys. The
# vendor binds it to loopback for that reason and warns against publishing it
# directly. So this module never moves it: it stays on 127.0.0.1 and an
# authenticating reverse proxy in front of it decides who gets through.
#
# That split matters. Binding the dashboard itself to a routable address puts an
# unauthenticated key-editing interface on the network; a proxy with credentials
# in front of a loopback service does not.

dashboard_apply() {
    is_true "${DASHBOARD_ENABLED:-false}" || { log_skip "dashboard disabled"; return 0; }
    log_step "Dashboard"

    if (( $(bot_count) > 0 )); then
        # The dashboard shows one profile: the bot declared with DASHBOARD=true.
        local key owner=""
        while IFS= read -r key; do
            [[ -n $key ]] && is_true "$(bot_field "$key" DASHBOARD)" && owner=$key
        done < <(bots)
        [[ -n $owner ]] || { log_skip "no bot has DASHBOARD=true; dashboard not published"; return 0; }
        _dashboard_retire_default
        bot_context "$owner"
        local SERVICE_NAME=$BOT_SERVICE
        _dashboard_apply_one
        bot_context_end
        return 0
    fi
    _dashboard_apply_one
}

# The default profile's dashboard unit holds the same loopback port the bot's
# dashboard needs; once a bot owns the dashboard, the old unit goes.
_dashboard_retire_default() {
    local unit="${SERVICE_NAME}-dashboard.service"
    have_cmd systemctl || return 0
    systemctl list-unit-files "$unit" 2>/dev/null | grep -q "${unit%%.*}" || return 0
    if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
        log_info "retiring the default-profile dashboard unit ${unit}"
        run systemctl disable --now "$unit"
        run rm -f "/etc/systemd/system/${unit}"
        run systemctl daemon-reload
        mark_changed
    fi
}

_dashboard_apply_one() {
    _dashboard_service

    is_true "${DASHBOARD_PROXY:-false}" || {
        log_skip "no proxy; reach the dashboard over an SSH tunnel:"
        log_info "  ssh -N -L ${DASHBOARD_PORT}:127.0.0.1:${DASHBOARD_PORT} <user>@<this-host>"
        return 0
    }

    _dashboard_drop_invented_key
    require_root "publishing the dashboard"
    _DASHBOARD_PROXY_COUNT_BEFORE=$CHANGE_COUNT
    _dashboard_install_proxy
    is_true "${DASHBOARD_PROXY_AUTH:-true}" && _dashboard_write_auth
    _dashboard_write_site
    _dashboard_open_firewall
    _dashboard_verify
}

dashboard_unit_name() { printf '%s-dashboard' "$SERVICE_NAME"; }

# The dashboard refuses a Host header it does not recognise:
#   {"detail":"Invalid Host header. Dashboard requests must use the bound
#    hostname or the configured public hostname."}
# Rewriting Host in the proxy would get past that and then fail on the
# WebSocket Origin guard, which sees the browser's real origin — the UI streams,
# so it would reconnect in a loop. Telling it its public address is the
# supported way, and it also engages the dashboard's own auth gate, which is
# only fair: once it answers on a routable address it should not depend on a
# proxy in front for its security.
_dashboard_write_env() {
    local pw secret
    pw=$(secret_require "$DASHBOARD_PROXY_PASSWORD_VAR" "the dashboard")

    # A stable signing key so sessions survive a restart. Generated once and
    # kept; regenerating it on every run would log everyone out on every run.
    secret=""
    [[ -f $DASHBOARD_ENV_FILE ]] && \
        secret=$(sed -n 's/^HERMES_DASHBOARD_BASIC_AUTH_SECRET=//p' "$DASHBOARD_ENV_FILE" | head -n1)
    [[ -n $secret ]] || secret=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
    log_redact_register "$secret"

    write_file "$DASHBOARD_ENV_FILE" 0600 <<EOF
# Managed by setup-hermes-agent. Read by ${SERVICE_NAME}-dashboard.service.
HERMES_DASHBOARD_PUBLIC_URL=http://${DASHBOARD_PROXY_BIND}:${DASHBOARD_PROXY_PORT}
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${DASHBOARD_PROXY_USER}
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${pw}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${secret}
EOF
}

# The dashboard is its OWN process, not something the gateway serves.
#
#   hermes dashboard    Start web UI dashboard (port 9119)
#
# There is no environment switch that makes the gateway host it — an earlier
# version of this module wrote HERMES_DASHBOARD=1 into the agent's .env, which
# is not a setting this software has. Nothing listened on the port, and the
# proxy in front answered 502 for a dashboard that was never started.
_dashboard_service() {
    local before=$CHANGE_COUNT
    local unit py dir
    unit=$(dashboard_unit_name)
    dir=$(hermes_install_dir)
    py="${dir}/venv/bin/python"

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] install ${unit}.service running the web UI on 127.0.0.1:${DASHBOARD_PORT}"
        log_info "[dry-run] write ${DASHBOARD_ENV_FILE} with the public URL and credentials"
        return 0
    fi
    _dashboard_write_env
    [[ -x $py ]] || die "no agent virtualenv at ${py}; the agent module has not run"

    require_root "installing the dashboard service"
    write_file "/etc/systemd/system/${unit}.service" 0644 <<EOF
# Managed by setup-hermes-agent.
[Unit]
Description=Agent web dashboard${BOT_KEY:+ (${BOT_DISPLAY_NAME})}
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=simple
${SERVICE_USER:+User=${SERVICE_USER}}
${SERVICE_GROUP:+Group=${SERVICE_GROUP}}
Environment=HERMES_HOME=${HERMES_CONFIG_HOME:-$HERMES_HOME}
# Credentials and the public URL come from a file, not from here: unit files
# under /etc/systemd/system are world-readable.
EnvironmentFile=${DASHBOARD_ENV_FILE}
# The first start may build the web assets with npm, which is slow; the unit is
# Type=simple so systemd does not wait, and the verification below does.
ExecStart=${py} -m hermes_cli.main dashboard --host 127.0.0.1 --port ${DASHBOARD_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${unit}

# It binds loopback only; the authenticating proxy is what publishes it.
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

    run systemctl daemon-reload
    converge_unit "${unit}.service" "$before"
    log_info "dashboard      127.0.0.1:${DASHBOARD_PORT} (loopback only, ${unit}.service)"
}

# HERMES_DASHBOARD was never a setting this software reads. Remove it rather
# than leave a key in the agent's .env that suggests it does something.
_dashboard_drop_invented_key() {
    # _env_file lives in the channels library, which is sourced alongside this
    # one. Naming it wrongly and swallowing the error would make this a silent
    # no-op — so require it rather than guess.
    declare -F _env_file >/dev/null 2>&1 || die "_env_file is missing; src/ is incomplete"
    local env; env=$(_env_file)
    [[ -f $env ]] || return 0
    grep -q '^HERMES_DASHBOARD=' "$env" || return 0
    log_info "removing HERMES_DASHBOARD from .env; it is not a setting the agent reads"
    run sed -i '/^HERMES_DASHBOARD=/d' "$env"
    mark_changed
}

_dashboard_install_proxy() {
    if have_cmd nginx; then
        log_skip "nginx present"
        return 0
    fi
    log_info "installing nginx"
    DEBIAN_FRONTEND=noninteractive run apt-get install -y nginx
    mark_changed
}

# Credentials are generated from the secrets file, never prompted or defaulted.
# A published dashboard without authentication is an open key editor.
_dashboard_write_auth() {
    local password
    password=$(secret_require "${DASHBOARD_PROXY_PASSWORD_VAR}" "the dashboard proxy")

    [[ ${#password} -ge 12 ]] ||
        log_warn "the dashboard password is short; it guards an interface that shows API keys"

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write /etc/nginx/hermes.htpasswd for user ${DASHBOARD_PROXY_USER}"
        return 0
    fi

    require_cmd openssl
    local hash
    hash=$(openssl passwd -apr1 "$password")
    # Here-string, not a pipe — see the note in 70-service.sh.
    write_file /etc/nginx/hermes.htpasswd 0640 "root:www-data" \
        <<<"${DASHBOARD_PROXY_USER}:${hash}"
}

_dashboard_write_site() {
    # The dashboard enforces its own authentication whenever its public URL is
    # non-loopback, so this outer layer is normally a second prompt for the same
    # door. It stays available for a deployment where the inner gate does not
    # engage — and _dashboard_verify refuses to finish if NEITHER does.
    local _DASH_AUTH_BLOCK=""
    if is_true "${DASHBOARD_PROXY_AUTH:-true}"; then
        _DASH_AUTH_BLOCK='    auth_basic           "Hermes Agent";
    auth_basic_user_file /etc/nginx/hermes.htpasswd;
'
    fi

    # Ubuntu's packaged default server also listens on :80. Left enabled it
    # either wins the address or makes nginx refuse to start.
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        log_info "disabling nginx's default site (it also claims port 80)"
        run rm -f /etc/nginx/sites-enabled/default
        mark_changed
    fi

    write_file /etc/nginx/sites-available/hermes-dashboard 0644 <<EOF
# Managed by setup-hermes-agent.
#
# Publishes the loopback-bound dashboard on one address, behind credentials.
# The dashboard is never bound to a routable address itself.
server {
    listen ${DASHBOARD_PROXY_BIND}:${DASHBOARD_PROXY_PORT};
    server_name _;

${_DASH_AUTH_BLOCK}
    # The dashboard streams; without these the connection is closed on upgrade
    # and the page reconnects in a loop.
    proxy_http_version 1.1;
    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host       \$host;
    proxy_set_header X-Real-IP  \$remote_addr;
    proxy_read_timeout 300s;
    proxy_buffering off;

    location / {
        proxy_pass http://127.0.0.1:${DASHBOARD_PORT};
    }
}
EOF

    ensure_dir /etc/nginx/sites-enabled 0755
    if [[ -L /etc/nginx/sites-enabled/hermes-dashboard ]]; then
        log_skip "site already enabled"
    else
        run ln -sf /etc/nginx/sites-available/hermes-dashboard /etc/nginx/sites-enabled/hermes-dashboard
        mark_changed
    fi

    # nginx refuses to start on a bad config; catching it here keeps a syntax
    # error from taking the web server down rather than just this site.
    if [[ $DRY_RUN != true ]]; then
        nginx -t >/dev/null 2>&1 || { nginx -t; die "the generated nginx configuration is invalid"; }
    fi
    # restart rather than reload when something changed: on a freshly installed
    # nginx a reload can reach a master still coming up with the packaged
    # default, and the new site never takes effect — which looked exactly like
    # a working install, down to an unauthenticated welcome page on every
    # interface. When nothing changed, leave it alone.
    converge_unit nginx.service "${_DASHBOARD_PROXY_COUNT_BEFORE:-0}"
}

_dashboard_open_firewall() {
    is_true "${FIREWALL_MANAGE:-false}" || return 0
    have_cmd ufw || return 0
    # As narrow as the bind. The configuration refuses DASHBOARD_PROXY_BIND=0.0.0.0
    # and insists on a named address; opening the port on every interface would
    # undo that decision in the one place nobody looks. It matters wherever the
    # host has, or later gains, a second interface — a perimeter that already
    # permits 80 inbound plus a blanket local rule is the whole exposure.
    if [[ -n ${DASHBOARD_PROXY_BIND:-} && $DASHBOARD_PROXY_BIND != 0.0.0.0 ]]; then
        run ufw allow to "$DASHBOARD_PROXY_BIND" port "$DASHBOARD_PROXY_PORT" proto tcp
    else
        run ufw allow "${DASHBOARD_PROXY_PORT}/tcp"
    fi
}

_dashboard_verify() {
    [[ $DRY_RUN == true ]] && return 0

    local url="http://${DASHBOARD_PROXY_BIND}:${DASHBOARD_PROXY_PORT}/"
    local code waited=0 pw=""
    [[ -n ${DASHBOARD_PROXY_PASSWORD_VAR:-} ]] && pw=$(secret_get "$DASHBOARD_PROXY_PASSWORD_VAR" || printf '')

    # Every outcome here was a warning once, including "answered without
    # credentials". A dashboard that serves API keys to anyone who asks is the
    # failure this proxy exists to prevent, so it ends the run rather than
    # scrolling past in yellow.
    while (( waited < 30 )); do
        code=$(http_status "$url")
        case $code in
            401)
                # 401 proves the proxy demands credentials — it is produced
                # BEFORE anything is forwarded, so on its own it says nothing
                # about whether there is a dashboard behind it. Accepting it
                # was how a 502 for a service that had never been started got
                # reported as a successful publication.
                local behind
                behind=$(http_status "$url" --user "${DASHBOARD_PROXY_USER}:${pw}")
                case $behind in
                    502|503|504)
                        log_warn "auth is enforced, but the dashboard behind it answered ${behind}"
                        ;;
                    000)
                        log_warn "auth is enforced, but the dashboard behind it did not answer"
                        ;;
                    *)
                        log_ok "dashboard published at ${url} (authentication required; upstream ${behind})"
                        _dashboard_warn_plaintext
                        return 0
                        ;;
                esac
                ;;
            302|303)
                # No proxy auth: the dashboard itself must be the gate. A
                # redirect to its login page is that gate answering.
                local loc
                loc=$(curl -sS -o /dev/null -D - "$url" 2>/dev/null | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r')
                if [[ $loc == */login* ]]; then
                    log_ok "dashboard published at ${url} (its own login gate: ${loc})"
                    _dashboard_warn_plaintext
                    return 0
                fi
                log_error "${url} redirects to '${loc:-?}', which is not a login."
                die "the dashboard is published without an authentication gate"
                ;;
            200)
                log_error "${url} answered without credentials."
                log_error "  The dashboard displays and edits every API key on this host, and"
                log_error "  the proxy in front of it exists to stop that being public."
                log_error "  Check that nginx is serving the generated site:"
                log_error "    nginx -T | grep -c auth_basic        # expect 1 or more"
                log_error "    ss -lntp | grep ':${DASHBOARD_PROXY_PORT}'   # expect ${DASHBOARD_PROXY_BIND}, not 0.0.0.0"
                die "the dashboard is published without authentication"
                ;;
        esac
        sleep 3
        waited=$(( waited + 3 ))
    done

    log_error "the dashboard did not answer at ${url} within 30s (last status ${code})."
    log_error "  The web UI is its own service; check it before the proxy:"
    log_error "    systemctl status $(dashboard_unit_name)"
    log_error "    journalctl -u $(dashboard_unit_name) -n 40"
    case $code in
        000) log_error "  Nothing is listening there, or the address is not on this host." ;;
        502|503) log_error "  The proxy is up but the gateway behind it is not answering." ;;
        *)   log_error "  Unexpected status; nginx is serving something other than this site." ;;
    esac
    die "the dashboard is not reachable"
}

_dashboard_warn_plaintext() {
    if [[ ${DASHBOARD_PROXY_PORT} == 80 || ${DASHBOARD_PROXY_PORT} == 8080 ]]; then
        log_warn "this is plain HTTP: the password and everything the dashboard shows"
        log_warn "  — including API keys — cross the network in clear text."
    fi
}

# shellcheck shell=bash
#
# Inbound tunnel.
#
# Only channels that receive webhooks need this. Long-polling and IMAP-polling
# channels are outbound and require no inbound at all, so on an installation
# without a webhook channel this module does nothing and the host keeps no
# publicly reachable port.
#
# Two modes:
#   api       every step through the provider API — no browser, no interaction
#   assisted  browser login once, then the provider CLI does the rest
#
# Both are idempotent: an existing tunnel with the configured name is reused, and
# the DNS record is updated in place rather than duplicated.

tunnel_apply() {
    if [[ $TUNNEL_MODE == none ]]; then
        log_skip "no inbound tunnel (TUNNEL_MODE=none)"
        return 0
    fi

    log_step "Inbound tunnel"
    require_root "installing the tunnel daemon"

    _tunnel_install_daemon

    case $TUNNEL_MODE in
        api)      _tunnel_via_api ;;
        assisted) _tunnel_via_assisted ;;
        *)        die "unsupported TUNNEL_MODE: ${TUNNEL_MODE}" ;;
    esac

    _tunnel_verify
}

# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------
_tunnel_install_daemon() {
    if have_cmd cloudflared; then
        log_skip "cloudflared present ($(cloudflared --version 2>/dev/null | head -n1))"
        return 0
    fi

    log_info "installing cloudflared"
    ensure_dir /etc/apt/keyrings 0755
    run_sh "curl --proto '=https' --tlsv1.2 -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /etc/apt/keyrings/cloudflare-main.gpg"
    run chmod a+r /etc/apt/keyrings/cloudflare-main.gpg

    write_file /etc/apt/sources.list.d/cloudflared.sources 0644 <<EOF
# Managed by setup-hermes-agent.
Types: deb
URIs: https://pkg.cloudflare.com/cloudflared
Suites: any
Components: main
Architectures: $(detect_arch)
Signed-By: /etc/apt/keyrings/cloudflare-main.gpg
EOF

    run apt-get update
    DEBIAN_FRONTEND=noninteractive run apt-get install -y cloudflared
    mark_changed
}

# ---------------------------------------------------------------------------
# API mode
# ---------------------------------------------------------------------------

_tunnel_need_jq() {
    have_cmd jq && return 0
    log_info "installing jq (needed to read API responses)"
    DEBIAN_FRONTEND=noninteractive run apt-get install -y jq
    mark_changed
}

# _cf_api METHOD PATH [BODY_JSON]
#
# The credential goes through a temporary config file rather than the command
# line, where every user on the host could read it out of ps.
_cf_api() {
    local method=$1 path=$2 body=${3:-}
    local token cfg out
    token=$(secret_require "$TUNNEL_API_TOKEN_VAR" "TUNNEL_MODE=api")

    cfg=$(mktemp); chmod 0600 "$cfg"
    {
        printf 'header = "Authorization: Bearer %s"\n' "$token"
        printf 'header = "Content-Type: application/json"\n'
    } >"$cfg"

    local -a args=(--proto '=https' -fsS -X "$method" --config "$cfg"
                   --connect-timeout 10 --max-time 60)
    [[ -n $body ]] && args+=(--data "$body")

    # Three attempts: a single transport hiccup on one of a dozen calls per
    # run used to kill the whole run ("request failed") with nothing wrong.
    local attempt
    for attempt in 1 2 3; do
        out=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4${path}" 2>/dev/null) && break
        out=""
        (( attempt < 3 )) && sleep $(( attempt * 3 ))
    done
    [[ -n $out ]] || { rm -f "$cfg"; die "Cloudflare API request failed after 3 attempts: ${method} ${path}"; }
    rm -f "$cfg"

    if [[ $(jq -r '.success' <<<"$out" 2>/dev/null) != true ]]; then
        local msg
        msg=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$out" 2>/dev/null)
        die "Cloudflare API rejected ${method} ${path}: ${msg:-unknown error}"
    fi
    printf '%s' "$out"
}

_tunnel_via_api() {
    _tunnel_need_jq

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would verify the API token, then reuse or create tunnel '${TUNNEL_NAME}',"
        log_info "[dry-run] upsert ${TUNNEL_HOSTNAME} -> <tunnel>.cfargotunnel.com, publish only ${TUNNEL_INGRESS_PATH},"
        log_info "[dry-run] and install the daemon as a service"
        return 0
    fi

    local account_id tunnel_id zone_id
    account_id=$(secret_require "$TUNNEL_ACCOUNT_ID_VAR" "TUNNEL_MODE=api")

    _cf_verify_token "$account_id"

    tunnel_id=$(_cf_tunnel_ensure "$account_id")
    zone_id=$(_cf_zone_id "$TUNNEL_ZONE")

    local host
    while IFS= read -r host; do
        _cf_dns_upsert "$zone_id" "$tunnel_id" "$host"
    done < <(tunnel_hostnames)
    _cf_ingress_put "$account_id" "$tunnel_id"
    _cf_service_install "$account_id" "$tunnel_id"
    _cf_universal_ssl_ensure "$zone_id"
    while IFS= read -r host; do
        _cf_verify_edge_tls "$host"
    done < <(tunnel_hostnames)
}

# The public names: one per bot, or TUNNEL_HOSTNAME when there are no bots.
tunnel_hostnames() {
    if (( $(bot_count) > 0 )); then
        local key
        while IFS= read -r key; do [[ -n $key ]] && bot_field "$key" HOSTNAME && printf '\n'; done < <(bots)
    else
        printf '%s\n' "$TUNNEL_HOSTNAME"
    fi
    is_true "${SITE_ENABLED:-false}" && printf '%s\n' "$SITE_HOSTNAME"
    return 0
}

# tunnel_ingress_summary RULES_JSON -> one line naming every hostname rule
tunnel_ingress_summary() {
    jq -r '[.[] | select(.hostname) | "\(.hostname)\(.path // "") -> \(.service)"] | join(", ")' <<<"$1"
}

# The ingress rules as JSON: each bot's hostname to its own webhook port on
# loopback, the one path the platform posts to, everything else 404.
tunnel_ingress_rules() {
    if (( $(bot_count) > 0 )); then
        local key
        while IFS= read -r key; do
            [[ -n $key ]] || continue
            jq -nc --arg host "$(bot_field "$key" HOSTNAME)" --arg path "$TUNNEL_INGRESS_PATH" \
                   --arg svc "http://127.0.0.1:$(bot_field "$key" PORT)" '{hostname: $host, path: $path, service: $svc}'
        done < <(bots)
    else
        jq -nc --arg host "$TUNNEL_HOSTNAME" --arg path "$TUNNEL_INGRESS_PATH" --arg svc "$TUNNEL_INGRESS_TARGET" \
            '{hostname: $host, path: $path, service: $svc}'
    fi
    # The public pages: the whole hostname, every path.
    is_true "${SITE_ENABLED:-false}" &&
        jq -nc --arg host "$SITE_HOSTNAME" --arg svc "http://127.0.0.1:${SITE_PORT}" '{hostname: $host, service: $svc}'
    jq -nc '{service: "http_status:404"}'
}

# A proxied hostname is served by Cloudflare's edge, and the edge needs a
# certificate for the zone — Universal SSL. Without one every TLS handshake to
# every name in the zone fails with alert 40, the Bot Framework gets a
# connection error and answers the sender with 502, and not a single request
# ever reaches the tunnel: its counter stays at zero while every local
# component is healthy. This cost a day to find, because the same handshake
# failure seen from the host looked like local egress filtering.
_cf_universal_ssl_ensure() {
    local zone_id=$1 out
    out=$(_cf_api_try GET "/zones/${zone_id}/ssl/universal/settings") || {
        log_info "the API token cannot read the zone's Universal SSL setting"
        log_info "  (add Zone -> SSL and Certificates -> Edit to let this run manage it)"
        return 0
    }
    if [[ $(jq -r '.result.enabled' <<<"$out") == true ]]; then
        log_skip "universal SSL enabled on the zone"
        return 0
    fi
    log_warn "universal SSL is disabled on the zone; enabling it"
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] PATCH ssl/universal/settings enabled=true"; return 0; }
    _cf_api PATCH "/zones/${zone_id}/ssl/universal/settings" '{"enabled":true}' >/dev/null
    _CF_UNIVERSAL_SSL_JUST_ENABLED=true
    mark_changed
    log_ok "universal SSL enabled; the edge certificate can take minutes to an hour to issue"
}

_cf_report_cert_packs() {
    local zone_id packs
    zone_id=$(_cf_zone_id "$TUNNEL_ZONE" 2>/dev/null || printf '')
    [[ -n $zone_id ]] || return 0
    packs=$(_cf_api_try GET "/zones/${zone_id}/ssl/certificate_packs?status=all" 2>/dev/null \
            | jq -r '.result[]? | "  certificate pack: \(.type)  status=\(.status)  hosts=\(.hosts|join(","))"' 2>/dev/null || printf '')
    if [[ -n $packs ]]; then
        while IFS= read -r l; do log_info "$l"; done <<<"$packs"
    else
        log_info "  no certificate pack exists for the zone yet"
    fi
}

_cf_edge_handshake() {
    local TUNNEL_HOSTNAME=${1:-$TUNNEL_HOSTNAME}
    timeout 15 openssl s_client -4 -connect "${TUNNEL_HOSTNAME}:443" -servername "$TUNNEL_HOSTNAME" </dev/null 2>&1 || true
}

_cf_verify_edge_tls() {
    local TUNNEL_HOSTNAME=${1:-$TUNNEL_HOSTNAME}
    [[ $DRY_RUN == true ]] && return 0
    have_cmd openssl || return 0
    local out
    out=$(_cf_edge_handshake "$TUNNEL_HOSTNAME")

    # If THIS run switched Universal SSL on, a handshake failure right now is
    # not a misconfiguration but Cloudflare still issuing the certificate —
    # minutes, occasionally an hour. Give it a bounded wait, and if it is still
    # not there, defer: the tunnel is up, and nothing later in the run depends
    # on inbound TLS. Dying here left the Azure bot, the tools and the agent
    # itself uninstalled because of a certificate that was already on its way.
    if [[ ${_CF_UNIVERSAL_SSL_JUST_ENABLED:-false} == true ]] && grep -q 'alert handshake failure' <<<"$out"; then
        local waited=0
        log_info "waiting up to ${TUNNEL_EDGE_TLS_WAIT}s for Cloudflare to issue the edge certificate"
        while (( waited < TUNNEL_EDGE_TLS_WAIT )); do
            sleep 30; waited=$(( waited + 30 ))
            out=$(_cf_edge_handshake "$TUNNEL_HOSTNAME")
            grep -q 'alert handshake failure' <<<"$out" || { log_ok "edge certificate issued after ${waited}s"; break; }
        done
        if grep -q 'alert handshake failure' <<<"$out"; then
            defer_failure "edge certificate for ${TUNNEL_HOSTNAME} not issued within ${TUNNEL_EDGE_TLS_WAIT}s — Universal SSL is on; re-run once 'openssl s_client -connect ${TUNNEL_HOSTNAME}:443' shows a certificate"
            return 0
        fi
    fi

    if grep -q 'alert handshake failure' <<<"$out"; then
        # Say what Cloudflare itself says about the certificate, not just that
        # the handshake failed: "pending_validation" is a wait, an absent pack
        # is a configuration problem, and the operator should not have to guess.
        _cf_report_cert_packs
        log_error "Cloudflare's edge refuses TLS for ${TUNNEL_HOSTNAME} (alert handshake failure)."
        log_error "  The zone has no edge certificate. Nothing can reach the tunnel until it"
        log_error "  does — the Bot Framework will answer 502 and Teams shows the bot offline."
        log_error "  Dashboard: SSL/TLS -> Edge Certificates -> Universal SSL -> Enable, then"
        log_error "  wait for issuance; or give the API token Zone -> SSL and Certificates ->"
        log_error "  Edit and re-run, and this module enables it itself."
        die "no edge certificate for ${TUNNEL_HOSTNAME}"
    fi
    if grep -qE 'Verify return code: 0 \(ok\)' <<<"$out"; then
        log_ok "edge TLS for ${TUNNEL_HOSTNAME} verifies"
    else
        log_warn "could not confirm edge TLS for ${TUNNEL_HOSTNAME} from this host (no handshake failure, but no verified chain either)"
    fi
}

# Checking scopes up front turns "permission denied" three calls later into a
# named failure before anything has been created.
#
# Deliberately NOT /user/tokens/verify: that endpoint describes user-owned
# tokens only, and answers success:false for an account-owned one — which is
# what a token carrying "Cloudflare One Connector: cloudflared" has to be. It
# rejected working tokens. Exercising the two permissions the run actually
# needs is both correct for either kind and more useful, because it says which
# permission is missing rather than that "the token" is bad.
_cf_verify_token() {
    local account_id=$1 out

    if ! out=$(_cf_api_try GET "/zones?name=${TUNNEL_ZONE}"); then
        log_error "the token cannot read zone '${TUNNEL_ZONE}'."
        log_error "  Needs: Zone -> Zone -> Read, and Zone -> DNS -> Edit,"
        log_error "  scoped to include ${TUNNEL_ZONE}."
        die "Cloudflare token is missing zone permissions"
    fi
    [[ $(jq -r '.result | length' <<<"$out") -gt 0 ]] ||         die "zone '${TUNNEL_ZONE}' is not in this Cloudflare account"

    if ! _cf_api_try GET "/accounts/${account_id}/cfd_tunnel?is_deleted=false" >/dev/null; then
        log_error "the token cannot list tunnels in account ${account_id}."
        log_error "  Needs: Account -> Cloudflare One Connector: cloudflared -> Write."
        log_error "  (The older name for this is 'Cloudflare Tunnel', now legacy.)"
        die "Cloudflare token is missing tunnel permissions"
    fi

    log_ok "API token accepted for zone ${TUNNEL_ZONE} and account ${account_id}"
}

# _cf_api, but a rejection is a return code rather than the end of the run —
# so a caller can attribute the failure to a specific missing permission.
_cf_api_try() {
    local method=$1 path=$2
    local token cfg out
    token=$(secret_require "$TUNNEL_API_TOKEN_VAR" "TUNNEL_MODE=api")

    cfg=$(mktemp); chmod 0600 "$cfg"
    printf 'header = "Authorization: Bearer %s"\n' "$token" >"$cfg"
    out=$(curl --proto '=https' -fsS -X "$method" --config "$cfg" \
               --connect-timeout 10 --max-time 60 \
               "https://api.cloudflare.com/client/v4${path}" 2>/dev/null) || {
        rm -f "$cfg"; return 1
    }
    rm -f "$cfg"
    [[ $(jq -r '.success' <<<"$out" 2>/dev/null) == true ]] || return 1
    printf '%s' "$out"
}

_cf_zone_id() {
    local zone=$1 out id
    out=$(_cf_api GET "/zones?name=${zone}")
    id=$(jq -r '.result[0].id // empty' <<<"$out")
    [[ -n $id ]] || die "zone '${zone}' not found, or the token lacks Zone:Read on it"
    printf '%s' "$id"
}

# Reuse before create: running the provisioner twice must not leave two tunnels
# with the same name, which the API happily allows.
_cf_tunnel_ensure() {
    local account_id=$1 out id
    out=$(_cf_api GET "/accounts/${account_id}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")
    id=$(jq -r '.result[0].id // empty' <<<"$out")

    if [[ -n $id ]]; then
        log_skip "reusing existing tunnel '${TUNNEL_NAME}' (${id})"
    else
        out=$(_cf_api POST "/accounts/${account_id}/cfd_tunnel" \
              "$(jq -nc --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')")
        id=$(jq -r '.result.id' <<<"$out")
        [[ -n $id && $id != null ]] || die "tunnel creation returned no id"
        mark_changed
        log_ok "created tunnel '${TUNNEL_NAME}' (${id})"
    fi
    printf '%s' "$id"
}

# Update in place when the record already exists. Creating unconditionally
# would leave a second CNAME and non-deterministic resolution.
_cf_dns_upsert() {
    local zone_id=$1 tunnel_id=$2 TUNNEL_HOSTNAME=${3:-$TUNNEL_HOSTNAME}
    local target="${tunnel_id}.cfargotunnel.com"
    local out record_id current body

    out=$(_cf_api GET "/zones/${zone_id}/dns_records?name=${TUNNEL_HOSTNAME}")
    record_id=$(jq -r '.result[0].id // empty' <<<"$out")
    current=$(jq -r '.result[0].content // empty' <<<"$out")

    body=$(jq -nc --arg n "$TUNNEL_HOSTNAME" --arg c "$target" \
           '{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1}')

    if [[ -z $record_id ]]; then
        _cf_api POST "/zones/${zone_id}/dns_records" "$body" >/dev/null
        mark_changed
        log_ok "created DNS ${TUNNEL_HOSTNAME} -> ${target}"
    elif [[ $current == "$target" ]]; then
        log_skip "DNS already points at ${target}"
    else
        _cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null
        mark_changed
        log_ok "updated DNS ${TUNNEL_HOSTNAME}: ${current} -> ${target}"
    fi
}

# Publish exactly one path. Everything else answers 404, so the reachable
# surface is the one route the platform actually posts to and nothing more.
_cf_ingress_put() {
    local account_id=$1 tunnel_id=$2
    local body

    body=$(tunnel_ingress_rules | jq -sc '{config: {ingress: .}}')

    # Read before writing. The API accepts the same configuration any number of
    # times, and a PUT on every run is a call that counts against the account's
    # limits and a "changed" that was not one. Compare the ingress list we want
    # with the one that is there; write only on a difference.
    # -S sorts keys: the API returns the same rules with the keys in another
    # order, and a byte comparison of two equal configurations was never equal.
    local current wanted
    current=$(_cf_api GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
              | jq -Sc '.result.config.ingress // []' 2>/dev/null || printf '[]')
    wanted=$(jq -Sc '.config.ingress' <<<"$body")
    local summary
    summary=$(tunnel_ingress_summary "$wanted")
    if [[ $current == "$wanted" ]]; then
        log_skip "ingress already ${summary}"
        return 0
    fi

    _cf_api PUT "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$body" >/dev/null
    mark_changed
    log_ok "ingress: ${summary} (everything else 404)"
}

_cf_service_install() {
    local account_id=$1 tunnel_id=$2 out token
    local before=$CHANGE_COUNT

    # Fetched unconditionally, not only when installing: the unit reads the
    # token from a file, and that file has to exist on every run — see below.
    out=$(_cf_api GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/token")
    token=$(jq -r '.result' <<<"$out")
    log_redact_register "$token"
    [[ -n $token && $token != null ]] || die "could not obtain a tunnel token"

    # The unit file itself is the fact; `systemctl list-unit-files` answered
    # empty once during a daemon-reload and the install was attempted again,
    # which the vendor refuses ("already installed") and the run died on.
    if [[ -f /etc/systemd/system/cloudflared.service ]] ||
       systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared; then
        log_skip "cloudflared service already installed"
    else
        run cloudflared service install "$token"
        mark_changed
    fi

    # The vendor unit runs with --token-file. `service install` writes that file
    # once, and a service killed during startup has been observed restarting
    # with it gone — after which the tunnel cannot come up again at all, and the
    # error names a missing file rather than the start that failed. Owning the
    # file here makes its presence an invariant of the run instead of a
    # side effect of a command that already ran.
    ensure_dir "${TUNNEL_TOKEN_FILE%/*}" 0755
    write_file "$TUNNEL_TOKEN_FILE" 0600 <<<"$token"

    _cf_service_dropin
    converge_unit cloudflared.service "$before"
    _cf_service_verify
}

# The vendor unit is Type=notify with TimeoutStartSec=15. cloudflared prefers
# QUIC and falls back to HTTP/2 by itself, but the fallback takes longer than
# fifteen seconds on a network where UDP to the edge is degraded — so systemd
# kills it mid-fallback, and the run reports a failure that is really a
# deadline. Raise the deadline rather than fight the protocol.
_cf_service_dropin() {
    local bin exec=""
    bin=$(command -v cloudflared || printf /usr/bin/cloudflared)

    # The transport has to be a command-line flag. TUNNEL_PROTOCOL is recognised
    # — cloudflared logs it under "Environmental variables" — and then ignored:
    # the connection loop still reports "Initial protocol quic" and keeps
    # dialling UDP. Its own precheck even prints "will proceed using 'http2'"
    # while doing nothing of the sort, so the precheck is advisory only.
    #
    # --protocol no longer appears in `cloudflared tunnel run --help` in 2026.8.x
    # but still parses and still works; verified by connecting with it.
    #
    # Overriding ExecStart in a drop-in needs the empty assignment first, and
    # both halves of the command line are ours: the binary is resolved here and
    # the token file is written by this module.
    if [[ -n ${TUNNEL_PROTOCOL:-} ]]; then
        exec="ExecStart=
ExecStart=${bin} --no-autoupdate tunnel --protocol ${TUNNEL_PROTOCOL} run --token-file ${TUNNEL_TOKEN_FILE}"
    fi

    ensure_dir /etc/systemd/system/cloudflared.service.d 0755
    write_file /etc/systemd/system/cloudflared.service.d/10-provisioner.conf 0644 <<EOF
# Managed by setup-hermes-agent.
[Service]
# The vendor unit is Type=notify with TimeoutStartSec=15, shorter than a first
# connection takes on a degraded network.
TimeoutStartSec=${TUNNEL_START_TIMEOUT}
${exec}
EOF
    run systemctl daemon-reload
}

_cf_service_verify() {
    local waited=0
    while (( waited < TUNNEL_START_TIMEOUT )); do
        case $(systemctl is-active cloudflared.service 2>/dev/null) in
            active) log_ok "tunnel daemon connected"; return 0 ;;
            failed) break ;;
        esac
        sleep 3
        waited=$(( waited + 3 ))
    done

    log_error "the tunnel daemon did not connect within ${TUNNEL_START_TIMEOUT}s."

    # cloudflared runs its own connectivity precheck and states which transport
    # it believes will work. It does not then act on that conclusion — it keeps
    # retrying its preferred protocol with a growing backoff — so read the
    # verdict out of the log and name it rather than leaving the reader to.
    local suggested
    suggested=$(journalctl -u cloudflared.service -n 200 --no-pager 2>/dev/null \
                | grep -oP 'suggested_protocol=\K\S+' | tail -1)
    journalctl -u cloudflared.service -n 25 --no-pager >&2 || true

    if [[ -n $suggested && $suggested != "${TUNNEL_PROTOCOL:-}" ]]; then
        log_error ""
        log_error "  cloudflared's own precheck says this network wants '${suggested}'."
        log_error "  It does not switch by itself. Set this in config/hermes.conf:"
        log_error "      TUNNEL_PROTOCOL=\"${suggested}\""
        log_error "  then mirror the repository across and re-run."
    fi
    die "the tunnel daemon failed to start"
}

# ---------------------------------------------------------------------------
# Assisted mode
#
# For when an API token is not available. The one step that genuinely cannot be
# automated is the browser authorisation; everything after it proceeds normally.
# The host is headless, so the URL is printed for the operator to open elsewhere.
# ---------------------------------------------------------------------------
_tunnel_via_assisted() {
    local cert="${HOME:-/root}/.cloudflared/cert.pem"

    if [[ -f $cert ]]; then
        log_skip "already authorised ($cert)"
    else
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] would prompt for browser authorisation"
            return 0
        fi
        log_warn "Browser authorisation is required, and this host has no browser."
        log_warn "A URL follows: open it on your own machine, choose the zone '${TUNNEL_ZONE}',"
        log_warn "and this step continues by itself once you have."
        run cloudflared tunnel login || die "authorisation did not complete"
        [[ -f $cert ]] || die "authorisation finished but ${cert} was not written"
        mark_changed
    fi

    if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$TUNNEL_NAME"; then
        log_skip "reusing existing tunnel '${TUNNEL_NAME}'"
    else
        run cloudflared tunnel create "$TUNNEL_NAME"
        mark_changed
    fi

    run cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$TUNNEL_HOSTNAME"

    ensure_dir /etc/cloudflared 0755
    write_file /etc/cloudflared/config.yml 0644 <<EOF
# Managed by setup-hermes-agent.
tunnel: ${TUNNEL_NAME}
ingress:
  - hostname: ${TUNNEL_HOSTNAME}
    path: ${TUNNEL_INGRESS_PATH}
    service: ${TUNNEL_INGRESS_TARGET}
  - service: http_status:404
EOF

    if ! systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared; then
        run cloudflared service install
        mark_changed
    fi
    run systemctl enable --now cloudflared.service
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
_tunnel_verify() {
    [[ $DRY_RUN == true ]] && return 0

    systemctl is-active --quiet cloudflared.service ||
        die "cloudflared is not running; check: journalctl -u cloudflared -n 50"
    log_ok "cloudflared is active"

    # DNS propagation is not instant; a miss here is worth reporting but is not
    # grounds for failing the run.
    if have_cmd getent && getent hosts "$TUNNEL_HOSTNAME" >/dev/null 2>&1; then
        log_ok "${TUNNEL_HOSTNAME} resolves"
    else
        log_warn "${TUNNEL_HOSTNAME} does not resolve yet; DNS may still be propagating"
    fi
}

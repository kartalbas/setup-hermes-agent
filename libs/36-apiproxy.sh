# shellcheck shell=bash
#
# The balance proxy: a loopback pass-through in front of a hosted API that
# appends the account's remaining balance to every final answer. One instance
# per provider in use (deepseek, moonshot), started only for bots that ask for
# it with BOT_<KEY>_LLM_BALANCE=true; their endpoint is rewired to the proxy in
# the channels module (bot_llm_apply). The key never lives here: the gateway
# sends it in the Authorization header, the proxy forwards it and uses it for
# the balance endpoint as well.
#
# Order: after `agyshim` (same code directory), before `hermes`.

apiproxy_unit_name() { printf '%s-balance-%s' "$SERVICE_NAME" "$1"; }      # apiproxy_unit_name PROVIDER
apiproxy_script_path() { printf '%s/balance_proxy.py' "$AGY_SHIM_LIB_DIR"; }

# The providers the bots want a balance for — each once.
apiproxy_providers() {
    local key p seen=""
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        is_true "$(bot_field "$key" LLM_BALANCE)" || continue
        p=$(apiproxy_provider_for "$key") || continue
        [[ " $seen " == *" $p "* ]] || { seen="$seen $p"; printf '%s\n' "$p"; }
    done < <(bots)
}

apiproxy_apply() {
    local -a wanted=()
    local p
    while IFS= read -r p; do [[ -n $p ]] && wanted+=("$p"); done < <(apiproxy_providers)
    if (( ${#wanted[@]} == 0 )); then
        log_skip "balance proxy not requested by any bot (BOT_<KEY>_LLM_BALANCE)"
        _apiproxy_retire_unused
        return 0
    fi
    log_step "Balance proxy"
    require_root "installing the balance proxy"
    _apiproxy_install_script
    for p in "${wanted[@]}"; do
        local before=$CHANGE_COUNT
        _apiproxy_write_unit "$p"
        converge_unit "$(apiproxy_unit_name "$p").service" "$before"
        _apiproxy_verify "$p"
    done
    _apiproxy_retire_unused "${wanted[@]}"
}

_apiproxy_install_script() {
    local source="${SCRIPT_DIR}/bot/api-proxy/balance_proxy.py"
    [[ -f $source ]] || die "bot/api-proxy/balance_proxy.py is missing"
    if [[ $DRY_RUN == true ]]; then log_info "[dry-run] install ${source} -> $(apiproxy_script_path)"; return 0; fi
    ensure_dir "$AGY_SHIM_LIB_DIR" 0755
    write_file "$(apiproxy_script_path)" 0644 <<<"$(cat "$source")"
}

apiproxy_unit_text() {            # apiproxy_unit_text PROVIDER -> unit file
    local p=$1 py; py=$(command -v python3 || printf /usr/bin/python3)
    cat <<EOF
# Managed by setup-hermes-agent: balance footer proxy for ${p}.
[Unit]
Description=Balance proxy for the ${p} API (appends the remaining balance to answers)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${SERVICE_USER:+User=${SERVICE_USER}}
${SERVICE_GROUP:+Group=${SERVICE_GROUP}}
ExecStart=${py} $(apiproxy_script_path) --provider ${p} --host 127.0.0.1 --port $(apiproxy_port "$p") --cache ${API_PROXY_CACHE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$(apiproxy_unit_name "$p")
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

_apiproxy_write_unit() {
    local p=$1 unit; unit=$(apiproxy_unit_name "$p")
    if [[ $DRY_RUN == true ]]; then log_info "[dry-run] write /etc/systemd/system/${unit}.service (port $(apiproxy_port "$p"))"; return 0; fi
    local before=$CHANGE_COUNT
    write_file "/etc/systemd/system/${unit}.service" 0644 <<<"$(apiproxy_unit_text "$p")"
    (( CHANGE_COUNT > before )) && run systemctl daemon-reload
    return 0
}

_apiproxy_verify() {
    local p=$1 code
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] would check http://127.0.0.1:$(apiproxy_port "$p")/healthz"; return 0; }
    code=$(http_status "http://127.0.0.1:$(apiproxy_port "$p")/healthz")
    [[ $code == 200 ]] || { sleep 2; code=$(http_status "http://127.0.0.1:$(apiproxy_port "$p")/healthz"); }
    [[ $code == 200 ]] || die "balance proxy for ${p} does not answer on 127.0.0.1:$(apiproxy_port "$p") (HTTP ${code})"
    log_ok "balance proxy ${p} on 127.0.0.1:$(apiproxy_port "$p") -> $(apiproxy_upstream "$p")"
}

# A provider no bot asks for any more: its unit goes.
_apiproxy_retire_unused() {
    local p unit
    for p in deepseek moonshot; do
        [[ " $* " == *" $p "* ]] && continue
        unit=$(apiproxy_unit_name "$p")
        if [[ -f /etc/systemd/system/${unit}.service ]]; then
            if [[ $DRY_RUN == true ]]; then log_info "[dry-run] retire ${unit}"; continue; fi
            run systemctl disable --now "${unit}.service" 2>/dev/null || true
            run rm -f "/etc/systemd/system/${unit}.service"
            run systemctl daemon-reload
            mark_changed; log_ok "retired ${unit} (no bot asks for it)"
        fi
    done
}

apiproxy_uninstall() {
    local p
    for p in deepseek moonshot; do
        run systemctl disable --now "$(apiproxy_unit_name "$p").service" 2>/dev/null || true
        run rm -f "/etc/systemd/system/$(apiproxy_unit_name "$p").service"
    done
    run rm -f "$(apiproxy_script_path)"
}

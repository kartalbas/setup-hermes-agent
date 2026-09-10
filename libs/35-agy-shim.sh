# shellcheck shell=bash
#
# The CLI bridge: an OpenAI-compatible endpoint on loopback, backed by a
# subscription-authenticated coding-agent CLI.
#
# Ordered before the gateway, because the gateway is configured to talk to it
# and starting in the other order means a first request against nothing.
#
# The CLI's credentials belong to the service account, not to whoever runs the
# provisioner: they live in that account's home directory and are established by
# signing in as that account once. This module checks that rather than assuming
# it — an unauthenticated CLI fails only when the first message arrives, which
# is a bad time to find out.

agyshim_apply() {
    if ! is_true "${AGY_SHIM_ENABLED:-false}"; then
        log_skip "CLI bridge disabled (AGY_SHIM_ENABLED=false)"
        return 0
    fi

    log_step "CLI bridge"
    require_root "installing the bridge service"

    local before=$CHANGE_COUNT
    _agyshim_check_cli
    _agyshim_install_script
    _agyshim_tools_server
    _agyshim_write_unit
    converge_unit "$(agyshim_unit_name).service" "$before"
    _agyshim_verify
}

# systemd's compiled-in default PATH for units. Not the shell's, and notably
# without any home directory.
readonly _AGYSHIM_SYSTEMD_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
AGY_SHIM_BINARY_RESOLVED=""

agyshim_unit_name() { printf '%s-bridge' "$SERVICE_NAME"; }
agyshim_script_path() { printf '%s/agy_shim.py' "${AGY_SHIM_LIB_DIR}"; }
agyshim_tools_script_path() { printf '%s/tools_mcp.py' "${AGY_SHIM_LIB_DIR}"; }

# ---------------------------------------------------------------------------
# The CLI must exist and be signed in AS THE SERVICE ACCOUNT
# ---------------------------------------------------------------------------
_agyshim_check_cli() {
    local user=${SERVICE_USER:-$(id -un)}
    local found=""

    # Resolve first, so that a preview shows the path the unit will really
    # carry. The lookup uses a login shell, which reads .profile and so sees
    # ~/.local/bin; systemd does not — its default PATH stops at
    # /usr/local/bin. Writing the absolute path into the unit is what keeps a
    # check that passes from becoming a service that cannot start.
    if is_root && id -u "$user" >/dev/null 2>&1; then
        found=$(runuser -u "$user" -- bash -lc "command -v ${AGY_SHIM_BINARY}" 2>/dev/null || printf '')
        [[ -n $found ]] && AGY_SHIM_BINARY_RESOLVED=$found
    fi

    # Under a dry run the CLI module two steps earlier only announced the
    # install, so a missing binary here says nothing about the real run.
    if [[ $DRY_RUN == true ]]; then
        if [[ -n $found ]]; then
            log_info "[dry-run] ${AGY_SHIM_BINARY} resolves to ${found} for ${user}"
        else
            log_info "[dry-run] would verify that ${AGY_SHIM_BINARY} is installed and signed in for ${user}"
        fi
        return 0
    fi

    if [[ -z $found ]]; then
        log_error "${user} cannot find '${AGY_SHIM_BINARY}' on its PATH."
        log_error "  Its own installer puts it in ~/.local/bin, which is fine — the unit"
        log_error "  records the absolute path, so it does not need to be on a shared PATH."
        log_error "  What matters is that it belongs to this account, credentials included:"
        log_error "    sudo -u ${user} -H ${AGY_SHIM_BINARY}"
        die "the bridge has nothing to bridge to"
    fi
    log_ok "${AGY_SHIM_BINARY} found for ${user}: ${found}"
    case ":${_AGYSHIM_SYSTEMD_PATH}:" in
        *":${found%/*}:"*) ;;
        *) log_info "${found%/*} is not on systemd's default PATH; the unit names the binary in full" ;;
    esac

    # Credentials are per-account. A sign-in performed by an administrator does
    # not carry over to the service account, and that is the usual reason this
    # works interactively and then fails as a service.
    local home cred=""
    home=$(getent passwd "$user" | cut -d: -f6)
    for cred in "${home}/.gemini" "${home}/.config/antigravity" "${home}/.antigravity"; do
        [[ -d $cred ]] && break || cred=""
    done
    if [[ -z $cred ]]; then
        log_warn "no CLI credential directory under ${home}"
        log_warn "  sign in once as that account, from a terminal you can open a browser from:"
        log_warn "    sudo -u ${user} -H ${AGY_SHIM_BINARY}"
        confirm "Continue anyway and configure the bridge before signing in?" ||
            die "sign in first, then re-run"
    else
        log_ok "credentials present at ${cred}"
    fi
}

_agyshim_install_script() {
    ensure_dir "$AGY_SHIM_LIB_DIR" 0755

    local source="${SCRIPT_DIR}/bot/agy-shim/agy_shim.py"
    [[ -f $source ]] || die "the bridge script is missing at ${source}"

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] install ${source} -> $(agyshim_script_path)"
        return 0
    fi
    # write_file compares before writing, so an unchanged bridge is not
    # reinstalled and the service is not restarted for nothing.
    write_file "$(agyshim_script_path)" 0755 <<<"$(cat "$source")"
    local tools_src="${SCRIPT_DIR}/bot/agy-shim/tools_mcp.py"
    [[ -f $tools_src ]] || die "the tools server is missing at ${tools_src}"
    write_file "$(agyshim_tools_script_path)" 0755 <<<"$(cat "$tools_src")"
    # The installed bot's version, so a host can say which bot it runs.
    write_file "${AGY_SHIM_LIB_DIR}/VERSION" 0644 <<<"$(bot_version)"
}

# ---------------------------------------------------------------------------
# The caller's tools as REAL tools of the CLI (ADR 0024)
#
# Two files of the CLI's own, both written by the CLI as well, so both are
# MERGED rather than rendered: its MCP registry gets our server, and its
# settings get the allow rule without which headless mode auto-denies every
# call (verified E8, 2026-09-09). They belong to the service account, so the
# merge runs as that account.
#
# The server reads the tool list from ITS WORKING DIRECTORY — the CLI's
# per-conversation directory, written by the bridge before the spawn — so this
# one global entry serves every bot with that bot's own tools.
# ---------------------------------------------------------------------------
agyshim_cli_config_dir()   { printf '%s/.gemini/config' "$1"; }        # $1 = the account's home
agyshim_cli_settings()     { printf '%s/.gemini/antigravity-cli/settings.json' "$1"; }
agyshim_tools_server_name() { printf 'tools'; }

# The merge itself, as a program: reads the file (or starts from {}), applies
# the change, writes only when something differs, prints "changed" or "same".
# Kept here rather than in a helper file so the module stays self-contained.
_agyshim_merge_program() {
    cat <<'PY'
import json, os, sys
path, kind, a, b = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f) or {}
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    sys.exit(f"{path} is not a JSON object; leaving it alone")
before = json.dumps(data, sort_keys=True)
if kind == "server":
    servers = data.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        sys.exit(f"{path}: mcpServers is not an object")
    servers[a] = {"command": b, "args": [sys.argv[5]]}
else:
    allow = data.setdefault("permissions", {}).setdefault("allow", [])
    if not isinstance(allow, list):
        sys.exit(f"{path}: permissions.allow is not a list")
    if a not in allow:
        allow.append(a)
if json.dumps(data, sort_keys=True) == before:
    print("same")
    sys.exit(0)
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=1)
os.replace(tmp, path)
print("changed")
PY
}

_agyshim_tools_server() {
    local user=${SERVICE_USER:-$(id -un)} home name py out
    name=$(agyshim_tools_server_name)
    home=$(getent passwd "$user" | cut -d: -f6)
    py=$(command -v python3 || printf /usr/bin/python3)
    if [[ -z $home ]]; then
        log_warn "no home directory for ${user}; the CLI cannot be told about the tools server"
        return 0
    fi
    local mcp_config settings config_dir
    config_dir=$(agyshim_cli_config_dir "$home")
    mcp_config="${config_dir}/mcp_config.json"
    settings=$(agyshim_cli_settings "$home")

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] register the MCP server '${name}' (${py} $(agyshim_tools_script_path)) in ${mcp_config}"
        log_info "[dry-run] allow mcp(${name}/*) in ${settings}"
        return 0
    fi
    ensure_dir "$config_dir" 0755 "${user}:${SERVICE_GROUP:-$user}"

    if out=$(runuser -u "$user" -- "$py" -c "$(_agyshim_merge_program)" \
                "$mcp_config" server "$name" "$py" "$(agyshim_tools_script_path)" 2>&1); then
        case $out in
            changed) mark_changed; log_ok "MCP server '${name}' registered with the CLI (${mcp_config})" ;;
            *)       log_skip "MCP server '${name}' registered with the CLI" ;;
        esac
    else
        defer_failure "bridge: could not register the tools server with the CLI: ${out}"
        return 0
    fi

    # Without the allow rule the CLI auto-denies every call in headless mode:
    # the bridge salvages the arguments, but the model pays a turn for it.
    if [[ ! -f $settings ]]; then
        log_warn "no ${settings} yet (the CLI writes it on first use); re-run this module after the first sign-in so mcp(${name}/*) is allowed"
        return 0
    fi
    if out=$(runuser -u "$user" -- "$py" -c "$(_agyshim_merge_program)" \
                "$settings" allow "mcp(${name}/*)" - 2>&1); then
        case $out in
            changed) mark_changed; log_ok "the CLI may call the tools server (allow mcp(${name}/*))" ;;
            *)       log_skip "the CLI may call the tools server" ;;
        esac
    else
        defer_failure "bridge: could not allow mcp(${name}/*) in ${settings}: ${out}"
    fi
}

_agyshim_write_unit() {
    local unit; unit=$(agyshim_unit_name)
    local py; py=$(command -v python3 || printf /usr/bin/python3)
    local bin=${AGY_SHIM_BINARY_RESOLVED:-$AGY_SHIM_BINARY}
    local path=$_AGYSHIM_SYSTEMD_PATH
    [[ $bin == /* ]] && path="${bin%/*}:${path}"

    write_file "/etc/systemd/system/${unit}.service" 0644 <<EOF
# Managed by setup-hermes-agent.
[Unit]
Description=OpenAI-compatible bridge to a subscription CLI
After=network-online.target
Wants=network-online.target
# The gateway talks to this; starting the other way round means its first
# request meets a closed port.
Before=${SERVICE_NAME}.service

[Service]
Type=simple
# The CLI installs itself into the account's ~/.local/bin, which systemd's
# default PATH does not contain. ExecStart names it in full; this is for
# whatever the CLI itself invokes.
Environment=PATH=${path}
# The CLI updates itself in the background; a backend that changes under the
# bridge is not a state anyone can reason about. Updates are the operator's
# deliberate act ("agy update"). The bridge passes AGY_CLI_* through to the CLI.
Environment=AGY_CLI_DISABLE_AUTO_UPDATE=true
Environment=AGY_CLI_HIDE_ACCOUNT_INFO=true
${SERVICE_USER:+User=${SERVICE_USER}}
${SERVICE_GROUP:+Group=${SERVICE_GROUP}}
ExecStart=${py} $(agyshim_script_path) \\
    --binary ${bin} \\
    --host ${AGY_SHIM_HOST} \\
    --port ${AGY_SHIM_PORT} \\
    --models ${AGY_SHIM_MODELS} \\
    --unknown-model ${AGY_SHIM_UNKNOWN_MODEL} \\
    --max-concurrent ${AGY_SHIM_MAX_CONCURRENT} \\
    --max-processes ${AGY_SHIM_MAX_PROCESSES} \\
    --idle-timeout ${AGY_SHIM_IDLE_TIMEOUT} \\
    --compact-at ${AGY_SHIM_COMPACT_AT} \\
    --history-budget ${AGY_SHIM_HISTORY_BUDGET} \\
    --native-tools ${AGY_SHIM_NATIVE_TOOLS}${AGY_SHIM_MODEL_ALIASES:+ \\
    --model-aliases ${AGY_SHIM_MODEL_ALIASES}}
Restart=always
RestartSec=5
# Each conversation is a live CLI process holding context; give them time to
# finish rather than cutting a turn short on restart.
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${unit}

# The bridge itself only shuffles JSON. It does not need privileges, and the
# processes it spawns inherit this.
NoNewPrivileges=true
PrivateTmp=false
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

    run systemctl daemon-reload
}

_agyshim_verify() {
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] would verify the bridge answers"; return 0; }

    local unit url waited=0
    unit=$(agyshim_unit_name)
    url="http://${AGY_SHIM_HOST}:${AGY_SHIM_PORT}/v1/models"

    while (( waited < 30 )); do
        if [[ $(http_status "$url") == 200 ]]; then
            log_ok "bridge answering on ${AGY_SHIM_HOST}:${AGY_SHIM_PORT}"
            local models
            models=$(fetch "$url" 2>/dev/null | grep -oP '"id":\s*"\K[^"]+' | paste -sd', ')
            log_info "models         ${models}"
            return 0
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done

    log_error "the bridge did not answer within 30s; last 30 journal lines:"
    journalctl -u "${unit}.service" -n 30 --no-pager >&2 || true
    die "the bridge failed to start"
}

agyshim_uninstall() {
    local unit; unit=$(agyshim_unit_name)
    have_cmd systemctl || return 0
    if systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "$unit"; then
        run systemctl disable --now "${unit}.service" || true
        run rm -f "/etc/systemd/system/${unit}.service"
        run systemctl daemon-reload
        mark_changed
    fi
    [[ -f $(agyshim_script_path) ]] && run rm -f "$(agyshim_script_path)"
    [[ -f $(agyshim_tools_script_path) ]] && run rm -f "$(agyshim_tools_script_path)"
    return 0
}

# shellcheck shell=bash
#
# Preflight: everything that must be true before the first mutation.
#
# The point is to fail by name and early. A provisioner that dies half way
# through because a port was taken or a registry was unreachable leaves a host
# in a state nobody planned for; these checks run while that is still cheap.
#
# All checks are read-only, so they run normally under --dry-run.

preflight_apply() {
    log_step "Preflight"

    local -a problems=()

    _pf_platform      problems
    _pf_resources     problems
    _pf_commands      problems
    _pf_ports         problems
    _pf_existing      problems
    _pf_egress        problems

    if (( ${#problems[@]} )); then
        log_error "preflight failed:"
        local p
        for p in "${problems[@]}"; do log_error "  - $p"; done
        die "refusing to continue"
    fi

    log_ok "preflight passed"
}

# Each check appends to the named array rather than dying, so one run reports
# every problem instead of making the operator rediscover them one at a time.
_pf_add() {
    local -n _pf_arr=$1
    _pf_arr+=("$2")
}

_pf_platform() {
    local _pf_name=$1

    local id codename arch
    id=$(os_release_value ID 2>/dev/null || printf 'unknown')
    codename=$(distro_codename)
    arch=$(detect_arch)
    log_info "platform       ${id} ${codename:-?} (${arch})"

    if [[ $(stat -fc %T /sys/fs/cgroup 2>/dev/null) != cgroup2fs ]]; then
        _pf_add "$_pf_name" "cgroup v2 (unified hierarchy) is required"
    fi

    if [[ $SERVICE_SCOPE == system ]] && ! have_cmd systemctl; then
        _pf_add "$_pf_name" "systemctl not found, but SERVICE_SCOPE=system"
    fi

    if have_cmd systemctl; then
        local sd_ver
        sd_ver=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')
        log_info "systemd        ${sd_ver:-unknown}"
    fi
}

_pf_resources() {
    local _pf_name=$1

    local mem_kb mem_mb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || printf 0)
    mem_mb=$(( mem_kb / 1024 ))
    log_info "memory         ${mem_mb} MB"
    if (( mem_mb < 1024 )); then
        _pf_add "$_pf_name" "at least 1 GB of RAM is required, found ${mem_mb} MB"
    elif (( mem_mb < 2048 )); then
        log_warn "under 2 GB of RAM; expect trouble if browser tooling is enabled"
    fi

    # Check the filesystem holding the install target, not always /.
    local probe=${INSTALL_DIR:-/usr/local} avail_mb
    while [[ ! -d $probe && $probe != / ]]; do probe=$(dirname "$probe"); done
    avail_mb=$(df -Pm "$probe" 2>/dev/null | awk 'NR==2{print $4}')
    log_info "disk free      ${avail_mb:-?} MB on ${probe}"
    if [[ -n ${avail_mb:-} ]] && (( avail_mb < 5120 )); then
        _pf_add "$_pf_name" "at least 5 GB free is required on ${probe}, found ${avail_mb} MB"
    fi
}

_pf_commands() {
    local _pf_name=$1
    local c
    # The vendor installer brings its own python, node and uv; these are the
    # ones it expects to already exist.
    # jq is used by the tunnel module and python3 by the mail probe, the YAML
    # merge and the relay's virtualenv — all of which run BEFORE the devtools
    # module that would have installed them. Naming them here turns a confusing
    # mid-run failure into a named one before anything has changed.
    for c in git curl xz jq python3; do
        have_cmd "$c" || _pf_add "$_pf_name" "required command missing: $c"
    done
    have_cmd flock || log_warn "flock not found; concurrent-run protection is unavailable"
}

_pf_ports() {
    local _pf_name=$1
    have_cmd ss || _pf_add "$_pf_name" "ss is not available, so port conflicts cannot be checked"

    local -a wanted=()
    if (( $(bot_count) > 0 )); then
        local key
        while IFS= read -r key; do
            [[ -n $key ]] && bot_has_channel "$key" teams && wanted+=("$(bot_field "$key" PORT)")
        done < <(bots)
    else
        is_true "${CHANNEL_TEAMS_ENABLED:-false}" && wanted+=("${CHANNEL_TEAMS_PORT:-3978}")
    fi

    local port owner pid unit
    for port in ${wanted+"${wanted[@]}"}; do
        ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . || continue

        owner=$(ss -H -ltnp "sport = :${port}" 2>/dev/null | head -n1 | sed -E 's/.*users:\(\("([^"]+)".*/\1/')
        pid=$(ss -H -ltnp "sport = :${port}" 2>/dev/null | head -n1 | sed -E 's/.*,pid=([0-9]+),.*/\1/')

        # The point of this check is a FOREIGN process on a port we need. Our
        # own gateway holding it is the previous run's result, not a conflict —
        # and after the first successful install it holds every port we asked
        # for, which would make the provisioner refuse to run again.
        # The unit comes from the process's cgroup: `ps -o unit=` exists only
        # on some builds and silently yields nothing on the others, which would
        # turn this check back into the false alarm it was.
        unit=""
        if [[ $pid =~ ^[0-9]+$ && -r /proc/${pid}/cgroup ]]; then
            unit=$(grep -oE '[^/]+\.service' "/proc/${pid}/cgroup" 2>/dev/null | tail -n1)
        fi
        if [[ -n $unit ]] && { [[ $unit == "${SERVICE_NAME}.service" ]] || [[ $unit == "${BOT_SERVICE_PREFIX}-"*.service ]]; }; then
            log_skip "port ${port} held by ${unit}, as intended"
            continue
        fi

        _pf_add "$_pf_name" "port ${port} is already in use${owner:+ by ${owner}}${unit:+ (${unit})}"
    done
    return 0
}

_pf_existing() {
    local _pf_name=$1
    have_cmd systemctl || return 0

    # A user-scope unit alongside a system-scope one means two gateways sharing
    # one data directory. The stores are not built for concurrent writers, so
    # this is corruption waiting to happen rather than a tidiness issue.
    local user_unit="${SUDO_USER:+/home/${SUDO_USER}}${SUDO_USER:+/.config/systemd/user/${SERVICE_NAME}.service}"
    if [[ -n ${SUDO_USER:-} && -f $user_unit ]]; then
        _pf_add "$_pf_name" "a user-scope unit already exists at ${user_unit}; remove it before installing a system unit"
    fi

    if systemctl list-unit-files "${SERVICE_NAME}.service" 2>/dev/null | grep -q "${SERVICE_NAME}"; then
        log_info "existing       ${SERVICE_NAME}.service is already installed (will converge)"
    fi
    return 0
}

_pf_egress() {
    local _pf_name=$1

    local -a hosts=()
    hosts+=("$HERMES_INSTALLER_URL")
    hosts+=("https://github.com")
    is_true "$DOCKER_MANAGE" && [[ $TERMINAL_BACKEND == docker ]] && hosts+=("${DOCKER_APT_URL}/dists/")
    [[ $TUNNEL_MODE == api ]] && hosts+=("https://api.cloudflare.com/client/v4/user/tokens/verify")

    local url
    for url in "${hosts[@]}"; do
        if url_reachable "$url"; then
            log_debug "reachable: $url"
        else
            # Named individually: "no connectivity" without the host is the
            # least useful error a provisioner can produce behind a proxy.
            _pf_add "$_pf_name" "cannot reach ${url%%/dists/*}"
        fi
    done

    _pf_endpoints "$_pf_name"
    return 0
}

# Inference endpoints get a real authenticated probe, not just reachability.
# A wrong token is the most common cause of an install that "succeeds" and then
# does not work, and it is free to detect here.
_pf_endpoints() {
    local _pf_name=$1
    is_true "$LLM_VERIFY_TOKEN" || { log_debug "endpoint verification disabled"; return 0; }

    local i base token_var token code hdr
    for (( i = 1; i <= LLM_ENDPOINT_COUNT; i++ )); do
        base=$(endpoint_field "$i" BASE_URL)
        token_var=$(endpoint_field "$i" TOKEN_VAR)
        [[ -n $base ]] || continue
        token=""
        [[ -n $token_var ]] && token=$(secret_get "$token_var" || printf '')

        if [[ -n $token ]]; then
            # Through a file, never the command line, where it would be visible
            # in ps to every user on the host.
            hdr=$(mktemp); chmod 0600 "$hdr"
            printf 'header = "Authorization: Bearer %s"\n' "$token" >"$hdr"
            code=$(http_status "${base%/}/models" --config "$hdr")
            rm -f "$hdr"
        else
            # A credential-free endpoint is normal on loopback.
            code=$(http_status "${base%/}/models")
        fi

        case $code in
            200)     log_ok "endpoint ${i} answered /models (HTTP 200)" ;;
            401|403) _pf_add "$_pf_name" "endpoint ${i} rejected the token from '${token_var}' (HTTP ${code})" ;;
            000)
                # The local bridge is installed later in this same run, so its
                # port being closed now is expected rather than a fault.
                if [[ $base == http://127.0.0.1* || $base == http://localhost* ]]; then
                    log_info "endpoint ${i} (loopback) is not up yet; it is started later in this run"
                else
                    _pf_add "$_pf_name" "endpoint ${i} is unreachable"
                fi
                ;;
            404)     log_warn "endpoint ${i} returned 404 for /models; it may not implement that route" ;;
            *)       log_warn "endpoint ${i} returned HTTP ${code} for /models" ;;
        esac
    done
    return 0
}

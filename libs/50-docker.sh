# shellcheck shell=bash
#
# Container engine, used as the agent's terminal sandbox.
#
# Ordered before the agent is installed and started. If the engine arrives
# afterwards, the gateway spends its first window executing tool calls directly
# as the service account, which is the thing the sandbox exists to prevent.

docker_apply() {
    if ! is_true "$DOCKER_MANAGE"; then
        log_skip "docker unmanaged (DOCKER_MANAGE=false)"
        return 0
    fi
    if [[ $TERMINAL_BACKEND != docker ]]; then
        log_skip "docker not needed (TERMINAL_BACKEND=${TERMINAL_BACKEND})"
        return 0
    fi

    log_step "Container engine"

    if _docker_adequate; then
        log_skip "docker already installed and working"
    else
        require_root "installing the container engine"
        _docker_remove_conflicts
        _docker_configure_repo
        _docker_write_daemon_config      # before first start, so no restart is needed
        _docker_install_packages
        _docker_enable
    fi

    _docker_write_daemon_config          # converge config on a re-run too
    _docker_verify
    _docker_prepull_sandbox_image
}

# ---------------------------------------------------------------------------
# Is what is already here good enough?
# ---------------------------------------------------------------------------
_docker_adequate() {
    have_cmd docker || return 1
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || return 1
    # Compose numbering moved to 5.x, so a check for "v2." reports a false
    # failure on a perfectly current installation. Compare properly.
    docker compose version --short >/dev/null 2>&1 || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Distribution packages conflict with the vendor ones at the package level.
# ---------------------------------------------------------------------------
_docker_remove_conflicts() {
    local -a present=()
    local pkg
    for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        dpkg -s "$pkg" >/dev/null 2>&1 && present+=("$pkg")
    done
    (( ${#present[@]} )) || { log_debug "no conflicting packages"; return 0; }

    log_warn "removing packages that conflict with docker-ce: ${present[*]}"
    run apt-get remove -y "${present[@]}"
    mark_changed
}

# ---------------------------------------------------------------------------
# APT repository, deb822 with a keyring — never apt-key, never trusted.gpg.d,
# which would grant the key blanket trust for every repository on the host.
# ---------------------------------------------------------------------------
_docker_configure_repo() {
    require_cmd curl gpg

    ensure_dir /etc/apt/keyrings 0755

    if [[ -f /etc/apt/keyrings/docker.asc ]]; then
        log_skip "docker keyring present"
    else
        run_sh "curl --proto '=https' --tlsv1.2 -fsSL '${DOCKER_GPG_URL}' -o /etc/apt/keyrings/docker.asc"
        run chmod a+r /etc/apt/keyrings/docker.asc
        mark_changed
    fi

    local suite
    suite=$(_docker_resolve_suite)
    log_info "apt suite      ${suite}"

    write_file /etc/apt/sources.list.d/docker.sources 0644 <<EOF
# Managed by setup-hermes-agent.
Types: deb
URIs: ${DOCKER_APT_URL}
Suites: ${suite}
Components: stable
Architectures: $(detect_arch)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # The convenience script writes the legacy one-line format to docker.list.
    # Leaving both in place produces duplicate-source warnings on every update.
    if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
        log_warn "removing legacy /etc/apt/sources.list.d/docker.list in favour of docker.sources"
        run rm -f /etc/apt/sources.list.d/docker.list
        mark_changed
    fi

    run apt-get update
}

# The distribution codename is usually right, but a repository does not always
# publish a suite for a release on its launch day, and derivatives report their
# own codename. Probe, then fall back, rather than letting apt fail with
# "does not have a Release file" halfway through.
_docker_resolve_suite() {
    if [[ -n $DOCKER_SUITE ]]; then
        printf '%s' "$DOCKER_SUITE"
        return 0
    fi
    local codename
    codename=$(distro_codename)
    if [[ -n $codename ]] && url_reachable "${DOCKER_APT_URL}/dists/${codename}/Release"; then
        printf '%s' "$codename"
        return 0
    fi
    log_warn "no repository suite published for '${codename:-unknown}'; falling back to ${DOCKER_SUITE_FALLBACK}"
    printf '%s' "$DOCKER_SUITE_FALLBACK"
}

_docker_install_packages() {
    log_info "installing docker-ce and plugins"
    DEBIAN_FRONTEND=noninteractive run apt-get install -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    mark_changed
}

# ---------------------------------------------------------------------------
# Daemon configuration
#
# Written before the daemon first starts. The default json-file driver does not
# rotate at all, so an always-on agent host will eventually fill its disk with
# container logs; and Docker's default bridge pools overlap ranges many VPNs
# use, which produces routing failures that look like application bugs.
# ---------------------------------------------------------------------------
_docker_write_daemon_config() {
    ensure_dir /etc/docker 0755

    local pools=""
    if [[ -n $DOCKER_ADDRESS_POOL_BASE ]]; then
        pools=$(printf ',\n  "default-address-pools": [{"base": "%s", "size": %s}]' \
                "$DOCKER_ADDRESS_POOL_BASE" "$DOCKER_ADDRESS_POOL_SIZE")
    fi

    write_file /etc/docker/daemon.json 0644 <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  },
  "live-restore": $(is_true "$DOCKER_LIVE_RESTORE" && printf true || printf false)${pools}
}
EOF
}

_docker_enable() {
    run systemctl enable --now docker.service containerd.service
    mark_changed
}

_docker_verify() {
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] would verify the engine"; return 0; }

    local server compose
    server=$(docker version --format '{{.Server.Version}}' 2>/dev/null) ||
        die "the docker daemon is not responding"
    compose=$(docker compose version --short 2>/dev/null || printf 'missing')
    log_ok "docker ${server}, compose ${compose}"
}

# ---------------------------------------------------------------------------
# Sandbox image
#
# Pulled now rather than on demand: the agent's first tool call would otherwise
# block on a cold image pull, which reads as the agent hanging.
# ---------------------------------------------------------------------------
_docker_prepull_sandbox_image() {
    is_true "$TERMINAL_IMAGE_PREPULL" || { log_skip "sandbox image pre-pull disabled"; return 0; }
    [[ -n $TERMINAL_DOCKER_IMAGE ]] || { log_debug "no sandbox image configured"; return 0; }

    if [[ $DRY_RUN != true ]] && docker image inspect "$TERMINAL_DOCKER_IMAGE" >/dev/null 2>&1; then
        log_skip "sandbox image present: ${TERMINAL_DOCKER_IMAGE}"
        return 0
    fi

    log_info "pulling sandbox image ${TERMINAL_DOCKER_IMAGE} (this takes a while)"
    run docker pull "$TERMINAL_DOCKER_IMAGE"
    mark_changed
}

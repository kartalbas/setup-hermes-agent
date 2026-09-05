# shellcheck shell=bash
#
# Teardown.
#
# Ordered so that nothing is removed while something still depends on it, and
# conservative about data: the agent's state directory and service account
# survive unless --purge is given, and even then only after confirmation.
# Everything else the provisioner created is removed.
#
# Uninstall is idempotent too: running it twice succeeds.

uninstall_apply() {
    log_step "Uninstall"

    if [[ $DO_PURGE == true ]]; then
        log_warn "--purge will delete the agent's accumulated state:"
        log_warn "  conversations, memory, and the skills it has written for itself."
        log_warn "  This is the part that cannot be rebuilt from this repository."
        confirm "Delete ${HERMES_HOME:-the agent data directory} permanently?" ||
            die "aborted"
    fi

    _uninstall_services
    _uninstall_units
    _uninstall_backup
    _uninstall_tunnel
    _uninstall_dashboard
    agyshim_uninstall
    assistant_uninstall
    _uninstall_code
    _uninstall_state
    _uninstall_account

    log_ok "uninstall complete"
    [[ $DO_PURGE == true ]] ||
        log_info "state kept at ${HERMES_HOME:-the data directory}; use --purge to remove it"
}

_uninstall_services() {
    have_cmd systemctl || return 0
    local unit key
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        for unit in "$(bot_field "$key" SERVICE).service" "$(bot_field "$key" SERVICE)-dashboard.service"; do
            systemctl list-unit-files "$unit" 2>/dev/null | grep -q "${unit%%.*}" && { run systemctl disable --now "$unit" || true; mark_changed; }
        done
    done < <(bots)
    for unit in "${SERVICE_NAME}.service" "${SERVICE_NAME}-backup.timer" "${SERVICE_NAME}-backup.service"; do
        if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "${unit%%.*}"; then
            run systemctl disable --now "$unit" || true
            mark_changed
        else
            log_skip "not installed: ${unit}"
        fi
    done
}

_uninstall_units() {
    have_cmd systemctl || return 0
    require_root "removing unit files"

    local path key
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        for path in "/etc/systemd/system/$(bot_field "$key" SERVICE).service" \
                    "/etc/systemd/system/$(bot_field "$key" SERVICE)-dashboard.service"; do
            [[ -f $path ]] && { run rm -f "$path"; mark_changed; }
        done
        [[ -d "/etc/systemd/system/$(bot_field "$key" SERVICE).service.d" ]] &&
            { run rm -rf "/etc/systemd/system/$(bot_field "$key" SERVICE).service.d"; mark_changed; }
    done < <(bots)
    for path in "/etc/systemd/system/${SERVICE_NAME}.service" \
                "/etc/systemd/system/${SERVICE_NAME}-backup.service" \
                "/etc/systemd/system/${SERVICE_NAME}-backup.timer"; do
        [[ -f $path ]] && { run rm -f "$path"; mark_changed; }
    done

    [[ -d "/etc/systemd/system/${SERVICE_NAME}.service.d" ]] &&
        { run rm -rf "/etc/systemd/system/${SERVICE_NAME}.service.d"; mark_changed; }

    # A user-scope unit may exist if the vendor installer ever created one.
    local home
    home=$(getent passwd "${SERVICE_USER:-$(id -un)}" 2>/dev/null | cut -d: -f6 || printf '')
    [[ -n $home && -f "${home}/.config/systemd/user/${SERVICE_NAME}.service" ]] &&
        { run rm -f "${home}/.config/systemd/user/${SERVICE_NAME}.service"; mark_changed; }

    run systemctl daemon-reload
    # Without this a unit that failed stays listed as failed after removal.
    run systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
}

_uninstall_backup() {
    [[ -f $(backup_script_path) ]] || return 0
    run rm -f "$(backup_script_path)"
    mark_changed
    log_info "backup archives at ${BACKUP_DEST:-the backup destination} were left in place"
}

# The tunnel daemon is stopped and its local configuration removed. The tunnel
# itself and its DNS record are left alone: they live in an account this
# provisioner does not own, other things may point at them, and deleting remote
# resources during an uninstall is a surprise nobody wants.
_uninstall_tunnel() {
    have_cmd systemctl || return 0
    if systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared; then
        run systemctl disable --now cloudflared.service || true
        mark_changed
        log_info "the remote tunnel and its DNS record were left in place; remove them"
        log_info "  in the provider's dashboard if nothing else uses them"
    fi
    [[ -f /etc/cloudflared/config.yml ]] && { run rm -f /etc/cloudflared/config.yml; mark_changed; }
    return 0
}

_uninstall_dashboard() {
    [[ -e /etc/nginx/sites-enabled/hermes-dashboard ]] || return 0
    run rm -f /etc/nginx/sites-enabled/hermes-dashboard
    run rm -f /etc/nginx/sites-available/hermes-dashboard
    run rm -f /etc/nginx/hermes.htpasswd
    mark_changed
    have_cmd systemctl && run systemctl reload-or-restart nginx || true
    log_info "nginx itself was left installed; remove it if nothing else uses it"
    return 0
}

_uninstall_code() {
    local dir
    dir=$(hermes_install_dir)
    if [[ -d $dir ]]; then
        # Refuse to delete anything that is not recognisably the installation.
        if [[ ! -d ${dir}/.git && ! -d ${dir}/venv ]]; then
            log_warn "${dir} does not look like an agent installation; leaving it alone"
            return 0
        fi
        run rm -rf "$dir"
        mark_changed
        log_ok "removed ${dir}"
    else
        log_skip "no installation directory at ${dir}"
    fi
}

_uninstall_state() {
    [[ $DO_PURGE == true ]] || return 0
    [[ -n ${HERMES_HOME:-} && -d $HERMES_HOME ]] || return 0
    run rm -rf "$HERMES_HOME"
    mark_changed
    log_ok "removed ${HERMES_HOME}"
}

# Removing an account can orphan files it owns elsewhere on the host, so this
# happens only with --purge and only for an account the provisioner created.
_uninstall_account() {
    [[ $DO_PURGE == true ]] || return 0
    [[ -n ${SERVICE_USER:-} ]] || return 0
    id -u "$SERVICE_USER" >/dev/null 2>&1 || { log_skip "no account ${SERVICE_USER}"; return 0; }

    if [[ $(id -u "$SERVICE_USER") -lt 1000 ]]; then
        run userdel "$SERVICE_USER" || log_warn "could not remove ${SERVICE_USER}"
        mark_changed
    else
        log_warn "${SERVICE_USER} is not a system account; leaving it alone"
    fi
}

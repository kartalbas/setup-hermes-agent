# shellcheck shell=bash
#
# Host preparation: timezone, service account, directories, firewall.
#
# Runs before anything that schedules work or writes agent configuration.

host_apply() {
    log_step "Host"
    _host_timezone
    _host_service_account
    _host_directories
    _host_firewall
    _host_journal_cap
    _host_tmpfiles
}

# Scratch the bots leave behind is short-lived by rule, not by hope: systemd's
# daily tmpfiles clean removes old files from every bot's work directory and
# from the download folders the assistants create for photos and scans.
host_tmpfiles_text() {
    cat <<EOF
# Managed by setup-hermes-agent: the bots' scratch space is short-lived.
# e = clean the contents of existing directories by age (systemd-tmpfiles-clean.timer, daily).
e ${HERMES_HOME}/profiles/*/work - - - 2d
e ${HERMES_HOME}/profiles/*/work/tmp - - - 2d
e ${HERMES_HOME}/work - - - 2d
e /tmp/onedrive-* - - - 1d
e /tmp/share-* - - - 1d
EOF
}

_host_tmpfiles() {
    [[ -n ${HERMES_HOME:-} ]] || return 0
    if [[ $DRY_RUN == true ]]; then log_info "[dry-run] write /etc/tmpfiles.d/hermes-provisioner.conf"; return 0; fi
    ensure_dir /etc/tmpfiles.d 0755
    write_file /etc/tmpfiles.d/hermes-provisioner.conf 0644 <<<"$(host_tmpfiles_text)"
}

# ---------------------------------------------------------------------------
# Timezone
#
# First, deliberately. The agent schedules reports and proposes appointments;
# both are generated in local time. A host left on UTC produces meetings offset
# by the local difference, and the symptom appears far from the cause.
# ---------------------------------------------------------------------------
_host_timezone() {
    have_cmd timedatectl || { log_warn "timedatectl not available; timezone unmanaged"; return 0; }

    local current
    current=$(timedatectl show -p Timezone --value 2>/dev/null || printf '')
    if [[ $current == "$TIMEZONE" ]]; then
        log_skip "timezone already ${TIMEZONE}"
        return 0
    fi

    if [[ ! -f /usr/share/zoneinfo/$TIMEZONE ]]; then
        die "unknown timezone '${TIMEZONE}' (no /usr/share/zoneinfo/${TIMEZONE})"
    fi

    run timedatectl set-timezone "$TIMEZONE"
    mark_changed
    log_ok "timezone ${current:-unset} -> ${TIMEZONE}"
}

# ---------------------------------------------------------------------------
# Service account
#
# Not created here. bootstrap.sh made it, and this runs inside it — so the job
# is to confirm that what is running is what was intended, not to create
# anything.
# ---------------------------------------------------------------------------
_host_service_account() {
    [[ -n $SERVICE_USER ]] || { log_debug "no service account resolved"; return 0; }

    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        log_error "account '${SERVICE_USER}' does not exist."
        log_error "  Run bootstrap.sh from an administrator account first; it creates"
        log_error "  the account and places this repository in its home."
        die "no service account"
    fi

    local home shell expected
    home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
    shell=$(getent passwd "$SERVICE_USER" | cut -d: -f7)
    log_info "account        ${SERVICE_USER} (home ${home}, shell ${shell})"

    # Existing is not the same as usable. An account left over from an earlier
    # attempt, or created by hand as a system account, passes the check above
    # and then fails much later: the subscription CLIs are installed and signed
    # in through a login shell, and HERMES_HOME is derived from the home
    # directory — so a nologin shell or a home somewhere unexpected produces a
    # broken installation whose symptom appears nowhere near the cause.
    case $shell in
        */nologin|*/false|"")
            log_error "account '${SERVICE_USER}' has shell '${shell:-none}'."
            log_error "  The subscription CLIs are installed and signed in through a login"
            log_error "  shell, so this account cannot host the agent."
            log_error "  Run bootstrap.sh, which gives it /bin/bash."
            die "service account has no login shell"
            ;;
    esac

    expected=${BOOTSTRAP_HOME:-/home/${SERVICE_USER}}
    if [[ $home != "$expected" ]]; then
        log_error "account '${SERVICE_USER}' lives at ${home}, but bootstrap.conf says ${expected}."
        log_error "  HERMES_HOME and every credential path derive from the home directory,"
        log_error "  so the two disagreeing means this run would configure one location"
        log_error "  and the agent would read another."
        log_error "  Either run bootstrap.sh to move it, or set BOOTSTRAP_HOME=\"${home}\"."
        die "service account home does not match the configuration"
    fi

    # Running as root with no SUDO_USER means this was invoked directly as root
    # rather than from inside the account, and the agent would end up owned by
    # root — which is not what any of this is arranged for.
    if [[ $SERVICE_USER == root ]]; then
        log_warn "running as root with no invoking account: the agent would run as root"
        log_warn "  log in as the service account and use sudo from there instead"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
_host_directories() {
    local owner=""
    [[ -n $SERVICE_USER ]] && owner="${SERVICE_USER}:${SERVICE_GROUP}"

    # State the provisioner itself keeps: the resolved revision, stage markers.
    ensure_dir "$PROVISIONER_STATE_DIR" 0750 "${owner:-}"

    if [[ -n $HERMES_HOME ]]; then
        ensure_dir "$HERMES_HOME" 0750 "${owner:-}"
    fi

    if is_true "$BACKUP_MANAGE" && [[ -n $BACKUP_DEST ]]; then
        ensure_dir "$BACKUP_DEST" 0750 "${owner:-}"
    fi
}

# ---------------------------------------------------------------------------
# Firewall
#
# Opt-in. Taking over firewall policy on a host that already has some is a good
# way to lock someone out of their own machine.
# ---------------------------------------------------------------------------
_host_firewall() {
    is_true "$FIREWALL_MANAGE" || { log_skip "firewall unmanaged (FIREWALL_MANAGE=false)"; return 0; }
    have_cmd ufw || { log_warn "ufw not installed; firewall unmanaged"; return 0; }
    require_root "configuring the firewall"

    # Local IFS, as above: without it a multi-port list becomes one bad rule.
    local port IFS=$' \t\n'
    for port in $FIREWALL_ALLOW_PORTS; do
        run ufw allow "${port}/tcp"
    done

    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        log_skip "ufw already active"
    else
        log_warn "enabling ufw with default-deny incoming; ${FIREWALL_ALLOW_PORTS} allowed"
        run ufw --force default deny incoming
        run ufw --force default allow outgoing
        run ufw --force enable
        mark_changed
    fi
}

# ---------------------------------------------------------------------------
# Journal cap
#
# The vendor unit ships StartLimitIntervalSec=0, so a gateway that cannot start
# retries every few seconds indefinitely. journald's default ceiling is a share
# of the filesystem, which on a small VM is a lot of log for one broken service.
# ---------------------------------------------------------------------------
_host_journal_cap() {
    [[ -n $JOURNAL_MAX_USE ]] || { log_debug "JOURNAL_MAX_USE unset; leaving journald defaults"; return 0; }
    have_cmd systemctl || return 0
    require_root "capping the journal"

    ensure_dir /etc/systemd/journald.conf.d 0755

    # Gate the restart on THIS write, not on the run-wide flag: CHANGED is
    # already true after the timezone or a directory changed, and journald was
    # restarted for those — losing the tail of the log on a run that never
    # touched it.
    local before=$CHANGE_COUNT
    write_file /etc/systemd/journald.conf.d/10-hermes-provisioner.conf 0644 <<EOF
# Managed by setup-hermes-agent. Bounds journal growth so a restart loop in one
# service cannot consume the filesystem.
[Journal]
SystemMaxUse=${JOURNAL_MAX_USE}
EOF

    if (( CHANGE_COUNT != before )); then
        run systemctl restart systemd-journald   # gated on the write above
    fi
}

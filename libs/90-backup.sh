# shellcheck shell=bash
#
# Backups of the agent's own state.
#
# What is worth protecting here is not the installation — that is reproducible
# from this repository in one run — but the data directory: conversations,
# accumulated memory, and the skills the agent has written for itself. None of
# that can be rebuilt.
#
# The agent's own backup command does the copying. That matters: it snapshots
# its SQLite databases through the database's backup interface and skips
# write-ahead logs, lock files and process state. An archive made with tar while
# the gateway is running captures databases mid-write and restores a stale lock
# alongside them.

backup_apply() {
    if ! is_true "$BACKUP_MANAGE"; then
        log_skip "backups unmanaged (BACKUP_MANAGE=false)"
        return 0
    fi

    log_step "Backup"
    require_root "installing the backup timer"

    _backup_write_script
    _backup_write_units
    _backup_enable
}

backup_script_path() {
    printf '%s/backup.sh' "$PROVISIONER_STATE_DIR"
}

_backup_write_script() {
    local dir py
    dir=$(hermes_install_dir)
    py="${dir}/venv/bin/python"

    write_file "$(backup_script_path)" 0750 "${SERVICE_USER:+${SERVICE_USER}:${SERVICE_GROUP}}" <<EOF
#!/usr/bin/env bash
# Managed by setup-hermes-agent. Edit the provisioner config, not this file.
set -Eeuo pipefail

DEST="${BACKUP_DEST}"
KEEP=${BACKUP_KEEP}
HERMES_HOME="${HERMES_HOME}"
export HERMES_HOME

stamp=\$(date +%Y%m%d-%H%M%S)
target="\${DEST}/hermes-\${stamp}"

mkdir -p "\$DEST"

# The agent's own backup: consistent database snapshots, no lock or WAL files.
"${py}" -m hermes_cli.main backup --output "\$target"

# Retention. Sorted by name, which is chronological given the stamp format.
mapfile -t archives < <(find "\$DEST" -maxdepth 1 -name 'hermes-*' -printf '%f\\n' | sort)
excess=\$(( \${#archives[@]} - KEEP ))
if (( excess > 0 )); then
    for (( i = 0; i < excess; i++ )); do
        rm -rf -- "\${DEST}/\${archives[i]}"
        printf 'pruned %s\\n' "\${archives[i]}"
    done
fi

printf 'backup complete: %s\\n' "\$target"
EOF
}

_backup_write_units() {
    write_file "/etc/systemd/system/${SERVICE_NAME}-backup.service" 0644 <<EOF
# Managed by setup-hermes-agent.
[Unit]
Description=Back up ${SERVICE_NAME} state
# After whatever this installation actually runs — the bots, or the single
# default gateway when there are none. Naming the default unit unconditionally
# ordered the backup against a unit that is retired as soon as bots exist.
After=$(service_consumer_units)

[Service]
Type=oneshot
${SERVICE_USER:+User=${SERVICE_USER}}
${SERVICE_GROUP:+Group=${SERVICE_GROUP}}
ExecStart=$(backup_script_path)
# A failed backup should be visible, not fatal to the host.
SuccessExitStatus=0
Nice=10
IOSchedulingClass=idle
EOF

    write_file "/etc/systemd/system/${SERVICE_NAME}-backup.timer" 0644 <<EOF
# Managed by setup-hermes-agent.
[Unit]
Description=Scheduled backup of ${SERVICE_NAME} state

[Timer]
OnCalendar=${BACKUP_ON_CALENDAR}
# Spreads load, and stops a fleet of hosts hitting the same storage at once.
RandomizedDelaySec=${BACKUP_RANDOM_DELAY}
# Runs after a reboot if the host was down when the timer was due.
Persistent=true
Unit=${SERVICE_NAME}-backup.service

[Install]
WantedBy=timers.target
EOF
}

_backup_enable() {
    run systemctl daemon-reload
    run systemctl enable --now "${SERVICE_NAME}-backup.timer"
    log_ok "backups ${BACKUP_ON_CALENDAR} -> ${BACKUP_DEST} (keeping ${BACKUP_KEEP})"

    # Restoring is the half nobody exercises until it matters, and it needs the
    # gateway stopped, so it is deliberately not automated here.
    log_info "restore is manual and requires the service stopped — see docs/runbook.md"
}

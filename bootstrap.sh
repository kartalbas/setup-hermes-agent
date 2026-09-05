#!/usr/bin/env bash
#
# Bootstrap: create the account the agent lives under, and put this repository
# in its home so everything afterwards happens there.
#
# OPTIONAL. The installer takes its account from whoever invokes it, so if you
# are content for the agent to run as an account that already exists — the one
# you are logged in as — skip this entirely and run install.sh directly.
#
# This exists for the other case: a dedicated account, separate from yours, that
# the agent lives in and that can be removed without touching anything else.
#
#   sudo ./bootstrap.sh --dry-run     show what it would do
#   sudo ./bootstrap.sh               do it
#
# Run this once, from an administrator account. After it, log in as the created
# user and run install.sh from the copy in its home. Nothing further happens
# from the administrator account, and nothing is edited outside the repository.
#
# Re-running is safe: the account is reused and the copy is re-synchronised, so
# this is also how you push a changed repository across after editing it here.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

# shellcheck source=src/00-log.sh
source "${SCRIPT_DIR}/libs/00-log.sh"
# shellcheck source=src/10-util.sh
source "${SCRIPT_DIR}/libs/10-util.sh"

usage() {
    cat <<'HELPTEXT'
Bootstrap the account the agent runs under.

USAGE
    sudo ./bootstrap.sh [options]

OPTIONS
    -c, --config FILE   account configuration
                        (default: config/bootstrap.conf, required)
    -u, --user NAME     override BOOTSTRAP_USER for this run
    -H, --home PATH     the account's home directory
                        (default: /home/<user>)
    -d, --dest PATH     where to place the repository
                        (default: <home>/setup-hermes-agent)
    -n, --dry-run       print what would happen, change nothing
    -y, --yes           do not ask
        --no-sudo       create the account without granting sudo
        --no-ssh        do not copy the current user's authorized_keys
    -h, --help          this text

AFTERWARDS
    sudo -u <user> -i               # or ssh <user>@this-host
    cd setup-hermes-agent
    ./install.sh --dry-run
    sudo ./install.sh
HELPTEXT
}

on_error() {
    local code=$? line=$1 cmd=$2
    log_error "failed at ${BASH_SOURCE[1]:-?}:${line} (exit ${code})"
    log_error "  while running: ${cmd}"
    return "$code"
}

parse_args() {
    CONFIG_FILE=""
    ACCOUNT=""
    HOMEDIR=""
    DEST=""
    GRANT_SUDO=true
    COPY_SSH=true

    while (( $# )); do
        case $1 in
            -c|--config) CONFIG_FILE=$2; shift 2 ;;
            -u|--user)   ACCOUNT=$2; shift 2 ;;
            -H|--home)   HOMEDIR=$2; shift 2 ;;
            -d|--dest)   DEST=$2; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -y|--yes)    ASSUME_YES=true; shift ;;
            --no-sudo)   GRANT_SUDO=false; shift ;;
            --no-ssh)    COPY_SSH=false; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

# Settings come from config/bootstrap.conf, which only this script reads. The
# installer does not need them: by the time it runs it is already this account.
load_bootstrap_config() {
    local cfg="${CONFIG_FILE:-${SCRIPT_DIR}/config/bootstrap.conf}"

    # Required, not optional. A missing configuration would otherwise fall back
    # to built-in defaults and create an account nobody asked for, named
    # something nobody chose — silently, and as root. Better to stop.
    if [[ ! -f $cfg ]]; then
        log_error "no configuration at ${cfg}"
        log_error "  This script creates an account and grants it privileges; it will not"
        log_error "  guess at either. The file is tracked in this repository — restore it"
        log_error "  with: git checkout -- config/bootstrap.conf"
        die "refusing to run without a configuration"
    fi

    local mode; mode=$(stat -c '%a' "$cfg")
    if (( 8#$mode & 8#022 )); then
        # It is sourced as root, so a group-writable copy is an injection point.
        log_error "${cfg} is writable by group or others (mode ${mode})"
        log_error "  it is sourced as root. Fix with: chmod 0644 ${cfg}"
        die "refusing to source a writable configuration file"
    fi

    # shellcheck disable=SC1090
    source "$cfg"

    ACCOUNT=${ACCOUNT:-${BOOTSTRAP_USER:-}}
    HOMEDIR=${HOMEDIR:-${BOOTSTRAP_HOME:-}}
    DEST=${DEST:-${BOOTSTRAP_DEST:-}}
    [[ -n ${BOOTSTRAP_GRANT_SUDO:-} ]] && [[ $GRANT_SUDO == true ]] && GRANT_SUDO=$BOOTSTRAP_GRANT_SUDO
    [[ -n ${BOOTSTRAP_COPY_SSH:-} ]]  && [[ $COPY_SSH == true ]]  && COPY_SSH=$BOOTSTRAP_COPY_SSH

    _validate_bootstrap_config "$cfg"
}

_validate_bootstrap_config() {
    local cfg=$1 problems=()

    [[ -n $ACCOUNT ]] || problems+=("BOOTSTRAP_USER is empty — name the account to create")
    [[ $ACCOUNT =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
        problems+=("BOOTSTRAP_USER='${ACCOUNT}' is not a valid account name")
    [[ $ACCOUNT == root ]] && problems+=("BOOTSTRAP_USER must not be root")
    [[ -z $HOMEDIR || $HOMEDIR == /* ]] || \
        problems+=("BOOTSTRAP_HOME must be an absolute path, got '${HOMEDIR}'")
    [[ -z $DEST || $DEST == /* ]] || \
        problems+=("BOOTSTRAP_DEST must be an absolute path, got '${DEST}'")
    is_true "$GRANT_SUDO" || [[ ${GRANT_SUDO,,} =~ ^(false|no|off|0)$ ]] || \
        problems+=("BOOTSTRAP_GRANT_SUDO must be true or false, got '${GRANT_SUDO}'")

    (( ${#problems[@]} == 0 )) && return 0
    log_error "${cfg} is not valid:"
    local p; for p in "${problems[@]}"; do log_error "  - $p"; done
    die "refusing to continue"
}

create_account() {
    HOMEDIR=${HOMEDIR:-/home/${ACCOUNT}}

    if id -u "$ACCOUNT" >/dev/null 2>&1; then
        log_skip "account ${ACCOUNT} exists"
        _fix_home
        # An account created by an earlier design had no login shell. It needs
        # one now, because the whole point is to work inside it.
        local shell; shell=$(getent passwd "$ACCOUNT" | cut -d: -f7)
        if [[ $shell == */nologin || $shell == */false ]]; then
            log_info "giving ${ACCOUNT} a login shell (was ${shell})"
            run usermod -s /bin/bash "$ACCOUNT"
            mark_changed
        fi
        return 0
    fi

    log_info "creating ${ACCOUNT} with home ${HOMEDIR}"
    run useradd --create-home --home-dir "$HOMEDIR" --shell /bin/bash \
        --user-group --comment "Hermes Agent" "$ACCOUNT"
    mark_changed
}

# An account made by the earlier design has the agent's DATA directory as its
# home, because nobody was meant to log in. That is no longer true: this is now
# a working account, and a home under /var/lib holding a repository is both
# surprising and awkward to reach.
_fix_home() {
    local current; current=$(getent passwd "$ACCOUNT" | cut -d: -f6)
    [[ $current == "$HOMEDIR" ]] && return 0

    log_warn "${ACCOUNT} has its home at ${current}"
    log_warn "  that is the agent's data directory, not a place to work in"
    log_info "moving it to ${HOMEDIR}"

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] usermod -d ${HOMEDIR} -m ${ACCOUNT}"
        return 0
    fi
    confirm "Move ${ACCOUNT}'s home from ${current} to ${HOMEDIR}?" || {
        log_warn "keeping ${current}; the repository will land inside the data directory"
        HOMEDIR=$current
        return 0
    }
    # -m moves the contents, so anything already there follows.
    run usermod -d "$HOMEDIR" -m "$ACCOUNT"
    mark_changed
    log_ok "home is now ${HOMEDIR}"
    log_warn "HERMES_HOME in the configuration may still point at the old path — check it"
}

grant_sudo() {
    if ! is_true "$GRANT_SUDO"; then
        log_skip "sudo not granted (--no-sudo)"
        return 0
    fi

    # Said once, plainly: this account runs an agent that reads untrusted mail
    # and executes its own code. Granting it sudo means an agent-level problem
    # reaches root. It is here because everything must be installable from
    # inside the account — see docs/decisions/0002.
    log_warn "${ACCOUNT} will be able to become root."
    log_warn "  The agent runs as this account and reads untrusted input."

    if getent group sudo >/dev/null 2>&1 && id -nG "$ACCOUNT" | tr ' ' '\n' | grep -qx sudo; then
        log_skip "${ACCOUNT} is already in the sudo group"
    else
        run usermod -aG sudo "$ACCOUNT"
        mark_changed
    fi

    # Passwordless, because the account has no password: it is reached by key or
    # by `sudo -u`, and a sudo prompt it can never answer would simply block.
    local file="/etc/sudoers.d/020-${ACCOUNT}"
    if [[ -f $file ]]; then
        log_skip "sudoers drop-in exists"
        return 0
    fi
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write ${file} granting NOPASSWD to ${ACCOUNT}"
        return 0
    fi
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$ACCOUNT" >"$file"
    chmod 0440 "$file"
    visudo -c -f "$file" >/dev/null || { rm -f "$file"; die "the generated sudoers file is invalid"; }
    mark_changed
    log_ok "sudo granted to ${ACCOUNT}"
}

# Reachable by the same key the administrator uses, so logging in needs no
# password on an account that deliberately has none.
copy_ssh_access() {
    if ! is_true "$COPY_SSH"; then
        log_skip "authorized_keys not copied (--no-ssh)"
        return 0
    fi
    local from="${SUDO_USER:-}" src home
    [[ -n $from ]] || { log_skip "not invoked through sudo; no keys to copy"; return 0; }

    src=$(getent passwd "$from" | cut -d: -f6)/.ssh/authorized_keys
    [[ -f $src ]] || { log_skip "${from} has no authorized_keys"; return 0; }

    home=$HOMEDIR
    if [[ -f "${home}/.ssh/authorized_keys" ]] && cmp -s "$src" "${home}/.ssh/authorized_keys"; then
        log_skip "authorized_keys already current"
        return 0
    fi
    run install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" "${home}/.ssh"
    run install -m 0600 -o "$ACCOUNT" -g "$ACCOUNT" "$src" "${home}/.ssh/authorized_keys"
    mark_changed
    log_ok "ssh access copied from ${from}"
}

# The whole repository, including the gitignored configuration and credentials:
# they are the point. Without them the copy is a different installation.
copy_repository() {
    DEST=${DEST:-${HOMEDIR}/$(basename "$SCRIPT_DIR")}

    if [[ ${DEST%/} == "${SCRIPT_DIR%/}" ]]; then
        log_skip "already running from the destination"
        return 0
    fi

    log_info "copying the repository to ${DEST}"
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] rsync -a --delete ${SCRIPT_DIR}/ ${DEST}/"
        log_info "[dry-run]   including config/ and config/credentials/, which git ignores"
        return 0
    fi

    run install -d -m 0750 -o "$ACCOUNT" -g "$ACCOUNT" "$DEST"
    # rsync and not cp: --delete makes this a mirror, so a file removed in the
    # origin disappears here too. cp would leave it behind, and the copy would
    # drift from the repository it is supposed to reproduce — silently, and in
    # the direction of an installation nobody can reconstruct.
    have_cmd rsync || die "rsync is required to mirror the repository; install it first"
    run rsync -a --delete \
        --exclude '.git/index.lock' \
        "${SCRIPT_DIR}/" "${DEST}/"
    run chown -R "${ACCOUNT}:${ACCOUNT}" "$DEST"
    # The secrets keep their mode through the copy; assert it rather than trust.
    [[ -f "${DEST}/config/secrets.conf" ]] && run chmod 0600 "${DEST}/config/secrets.conf"
    mark_changed
    log_ok "repository at ${DEST}"
}

report() {
    DEST=${DEST:-${HOMEDIR}/$(basename "$SCRIPT_DIR")}
    {
        printf '\n'
        printf '  Everything from here happens as %s.\n\n' "$ACCOUNT"
        printf '    sudo -u %s -i          # or: ssh %s@%s\n' "$ACCOUNT" "$ACCOUNT" "$(hostname -f 2>/dev/null || hostname)"
        printf '    cd %s\n' "$(basename "$DEST")"
        printf '    ./install.sh --dry-run\n'
        printf '    sudo ./install.sh\n\n'
        printf '  From here on, the copy in %s is THE repository.\n' "$DEST"
        printf '  Work there as %s; delete this one so there is a single source of truth:\n' "$ACCOUNT"
        printf '    rm -rf %s\n\n' "$SCRIPT_DIR"
        printf '  Run from inside the copy, this script only converges the account.\n\n'
    } >&2
}

main() {
    [[ ${BASH_VERSINFO[0]:-0} -ge 4 ]] || { printf 'bash 4+ required\n' >&2; exit 1; }
    parse_args "$@"
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

    load_bootstrap_config
    [[ $DRY_RUN == true ]] || is_root || die "run this with sudo"

    log_step "Bootstrap"
    log_info "account        ${ACCOUNT}"
    [[ $DRY_RUN == true ]] && log_warn "dry run: nothing will be changed"

    create_account
    grant_sudo
    copy_ssh_access
    copy_repository

    printf '\n' >&2
    if [[ $DRY_RUN == true ]]; then
        log_info "dry run complete — nothing was changed"
    elif [[ ${CHANGED:-false} == true ]]; then
        log_ok "done"
    else
        log_ok "done — already in the desired state"
    fi
    report
}

main "$@"

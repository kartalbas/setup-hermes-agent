#!/usr/bin/env bash
#
# Hermes Agent provisioner.
#
# One config file, one run, the complete system. Idempotent: run it again and it
# converges, changing nothing that already matches.
#
#   ./install.sh --dry-run       show every intended action, change nothing
#   sudo ./install.sh            apply
#   ./install.sh --help          full usage
#
# Everything below is a function definition until `main "$@"` on the last line.
# That is deliberate: a truncated download then either fails to parse or defines
# functions and exits without touching the system.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
IFS=$'\n\t'

readonly PROVISIONER_VERSION="0.1.0"

# Modules run in this order within a single invocation. The order encodes real
# constraints, not preference:
#   host    before everything — timezone must be right before anything schedules
#   tunnel  before azure      — the bot's endpoint is the tunnel hostname
#   tunnel  before service    — the gateway should not start with no inbound
#   docker  before hermes     — otherwise the agent runs a window with no sandbox
#   service before channels   — a channel needs somewhere to deliver to
#   channels before dashboard — the dashboard shows what the channels configured
readonly MODULES=(preflight host credentials git tunnel azure google docker devtools clis mailproxy agyshim hermes profiles service channels assistant dashboard backup)

usage() {
    cat <<'HELPTEXT'
Hermes Agent provisioner

USAGE
    ./install.sh [options]

OPTIONS
    -c, --config FILE       site config      (default: config/hermes.conf)
        --install FILE      what to install  (default: config/install.conf)
        --account FILE      which account     (default: config/bootstrap.conf)
        --channels FILE     channel config   (default: config/channels.conf)
    -n, --dry-run           print intended actions, change nothing
    -y, --yes               assume yes; required when there is no terminal
        --log-level LEVEL   debug|info|warn|error
        --ref REF           install this revision instead of the configured one
        --uninstall         remove the service and installed code
        --purge             with --uninstall, also remove agent state and account
    -V, --version           print version and exit
    -h, --help              this text

MODULES
    preflight host credentials git tunnel docker devtools clis mailproxy agyshim hermes service channels dashboard backup

EXAMPLES
    ./install.sh --dry-run
    sudo ./install.sh
    sudo ./install.sh --uninstall

UPGRADING
    Raise the revision and re-run; the run is idempotent, so only what changed
    is touched and the service is restarted once:

        sudo ./install.sh --ref v2026.9.1

    Do NOT use the agent's own updater: it returns the checkout to the default
    branch, dropping the pin and putting unreleased code into production.

Configuration lives in config/. Secrets live in the file named by SECRETS_FILE,
outside this repository, mode 0600. See README.md.
HELPTEXT
}

# ---------------------------------------------------------------------------
# Failure reporting
#
# -E (errtrace) above is what makes this trap fire inside functions and command
# substitutions; without it the handler silently never runs where it matters.
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line=$1 cmd=$2
    printf '\n' >&2
    if declare -F log_error >/dev/null 2>&1; then
        log_error "failed at ${BASH_SOURCE[1]:-?}:${line} (exit ${exit_code})"
        log_error "  while running: ${cmd}"
        [[ -n ${CURRENT_MODULE:-} ]] && log_error "  in module: ${CURRENT_MODULE}"
    else
        printf 'error: failed at line %s (exit %s) running: %s\n' "$line" "$exit_code" "$cmd" >&2
    fi
    return "$exit_code"
}

# ASSUME_YES, LOG_LEVEL, DRY_RUN and DO_PURGE are read by the libraries in
# src/, which are sourced through a glob that shellcheck cannot follow — hence
# the disable rather than a genuine unused variable.
# shellcheck disable=SC2034
parse_args() {
    ACCOUNT_FILE="${SCRIPT_DIR}/config/bootstrap.conf"
    INSTALL_FILE="${SCRIPT_DIR}/config/install.conf"
    CONFIG_FILE="${SCRIPT_DIR}/config/hermes.conf"
    CHANNELS_FILE="${SCRIPT_DIR}/config/channels.conf"
    REF_OVERRIDE=""
    LOG_LEVEL_OVERRIDE=""
    DO_UNINSTALL=false
    DO_PURGE=false

    while (( $# )); do
        case $1 in
            -c|--config)     CONFIG_FILE=$2; shift 2 ;;
            --channels)      CHANNELS_FILE=$2; shift 2 ;;
            --install)       INSTALL_FILE=$2; shift 2 ;;
            --account)       ACCOUNT_FILE=$2; shift 2 ;;
            -n|--dry-run)    DRY_RUN=true; shift ;;
            -y|--yes)        ASSUME_YES=true; shift ;;
            --log-level)     LOG_LEVEL=$2; LOG_LEVEL_OVERRIDE=$2; shift 2 ;;
            --ref)           REF_OVERRIDE=$2; shift 2 ;;
            --uninstall)     DO_UNINSTALL=true; shift ;;
            --purge)         DO_PURGE=true; shift ;;
            -V|--version)    printf '%s\n' "$PROVISIONER_VERSION"; exit 0 ;;
            -h|--help)       usage; exit 0 ;;
            --)              shift; break ;;
            -*)              printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
            *)               printf 'unexpected argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

load_libraries() {
    local lib
    for lib in "${SCRIPT_DIR}"/libs/[0-9][0-9]-*.sh; do
        [[ -f $lib ]] || continue
        # shellcheck disable=SC1090
        source "$lib"
    done
}

run_modules() {
    local name fn
    for name in "${MODULES[@]}"; do
        fn="${name}_apply"
        if ! declare -F "$fn" >/dev/null 2>&1; then
            die "module '${name}' has no ${fn}() — src/ is incomplete"
        fi

        CURRENT_MODULE=$name
        "$fn"
        CURRENT_MODULE=""
    done

    if (( ${#DEFERRED_FAILURES[@]} > 0 )); then
        local f
        log_error ""
        log_error "the run completed its remaining work, but ${#DEFERRED_FAILURES[@]} thing(s) failed:"
        for f in "${DEFERRED_FAILURES[@]}"; do
            log_error "  - ${f}"
        done
        die "re-run once the cause is fixed; everything that succeeded is skipped"
    fi
}

run_uninstall() {
    declare -F uninstall_apply >/dev/null 2>&1 ||
        die "uninstall is not available — src/99-uninstall.sh is missing"
    CURRENT_MODULE=uninstall
    uninstall_apply
    CURRENT_MODULE=""
}

report_outcome() {
    printf '\n' >&2
    if [[ $DRY_RUN == true ]]; then
        log_info "dry run complete — nothing was changed"
    elif [[ ${CHANGED:-false} == true ]]; then
        log_ok "done — the host was changed"
    else
        log_ok "done — already in the desired state, nothing changed"
    fi
}

main() {
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    readonly SCRIPT_DIR

    [[ ${BASH_VERSINFO[0]:-0} -ge 4 ]] ||
        { printf 'error: bash 4 or newer is required (run with bash, not sh)\n' >&2; exit 1; }

    parse_args "$@"
    load_libraries

    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

    config_defaults
    # bootstrap.conf first: it names the account, and both scripts read the same
    # file so they cannot disagree about who the agent is. Then install.conf,
    # which carries the tracked defaults, then the site files that may override
    # them.
    config_load "$ACCOUNT_FILE" "$INSTALL_FILE" "$CONFIG_FILE" "$CHANNELS_FILE"
    config_defaults           # again: fills anything the files left unset

    # Everything lives beside the configuration it belongs to, inside the
    # repository and gitignored — so nothing has to be edited in a system
    # directory before the first run has even happened.
    : "${SECRETS_FILE:=${SCRIPT_DIR}/config/secrets.conf}"

    # A flag outranks the file, per the documented precedence.
    if [[ -n ${REF_OVERRIDE:-} ]]; then
        HERMES_REF=$REF_OVERRIDE
        log_warn "revision overridden for this run: ${HERMES_REF}"
        log_warn "  set HERMES_REF in the config to make it survive the next run"
    fi

    [[ $DRY_RUN == true ]] || acquire_lock

    # The documented precedence is flag > environment > config file, and
    # config_load sources the files — so anything named on the command line has
    # to be put back afterwards. Without this, --log-level debug was accepted,
    # overwritten by LOG_LEVEL in hermes.conf, and the run produced three debug
    # lines and no explanation of why.
    # shellcheck disable=SC2034  # read by the libraries in src/
    [[ -n ${LOG_LEVEL_OVERRIDE:-} ]] && LOG_LEVEL=$LOG_LEVEL_OVERRIDE

    secrets_load
    config_validate
    config_summary

    if [[ $DO_UNINSTALL == true ]]; then
        run_uninstall
    else
        run_modules
    fi

    report_outcome
}

main "$@"

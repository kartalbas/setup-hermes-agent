# shellcheck shell=bash
#
# Logging: level filtering, stderr discipline, secret redaction.
#
# Sourced, never executed. Defines functions and the redaction registry only.
#
# Everything diagnostic goes to stderr so that a function's stdout stays usable
# as a return value. Only deliberate output for the caller goes to stdout.

: "${LOG_LEVEL:=info}"

# Values registered here are replaced with a placeholder in every log line.
# Registration is by value, not by name, because the same secret may arrive
# through several variables.
declare -ga _LOG_REDACT=()

# log_redact_register VALUE...
#
# Values shorter than 8 characters are ignored: redacting them would riddle
# ordinary output with placeholders for no security gain.
log_redact_register() {
    local v
    for v in "$@"; do
        [[ -n ${v:-} && ${#v} -ge 8 ]] || continue
        _LOG_REDACT+=("$v")
    done
}

# log_redact TEXT -> TEXT with every registered secret masked.
log_redact() {
    local text=$1 secret
    for secret in ${_LOG_REDACT+"${_LOG_REDACT[@]}"}; do
        text=${text//"$secret"/'<redacted>'}
    done
    printf '%s' "$text"
}

_log_level_num() {
    case ${1,,} in
        debug) printf 10 ;;
        info)  printf 20 ;;
        warn)  printf 30 ;;
        error) printf 40 ;;
        *)     printf 20 ;;
    esac
}

_log_use_colour() {
    [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]
}

# _log LEVEL COLOUR LABEL MESSAGE...
_log() {
    local level=$1 colour=$2 label=$3
    shift 3
    (( $(_log_level_num "$level") < $(_log_level_num "$LOG_LEVEL") )) && return 0

    local msg
    msg=$(log_redact "$*")

    if _log_use_colour; then
        printf '\033[%sm%-5s\033[0m %s\n' "$colour" "$label" "$msg" >&2
    else
        printf '%-5s %s\n' "$label" "$msg" >&2
    fi
}

log_debug() { _log debug '2;37' 'debug' "$@"; }
log_info()  { _log info  '0;36' 'info'  "$@"; }
log_warn()  { _log warn  '0;33' 'warn'  "$@"; }
log_error() { _log error '0;31' 'error' "$@"; }

# log_step MESSAGE — a heading for a unit of work, always shown.
log_step() {
    local msg
    msg=$(log_redact "$*")
    if _log_use_colour; then
        printf '\n\033[1m==> %s\033[0m\n' "$msg" >&2
    else
        printf '\n==> %s\n' "$msg" >&2
    fi
}

# log_ok MESSAGE — confirmation that something is now in the desired state.
log_ok() {
    local msg
    msg=$(log_redact "$*")
    if _log_use_colour; then
        printf '\033[0;32m  ok\033[0m  %s\n' "$msg" >&2
    else
        printf '  ok  %s\n' "$msg" >&2
    fi
}

# log_skip MESSAGE — already in the desired state; nothing was changed.
# Distinct from log_ok so an idempotent re-run reads clearly.
log_skip() {
    local msg
    msg=$(log_redact "$*")
    if _log_use_colour; then
        printf '\033[2m  --\033[0m  %s\n' "$msg" >&2
    else
        printf '  --  %s\n' "$msg" >&2
    fi
}

# die MESSAGE... — report and exit non-zero. Never call from a conditional.
die() {
    log_error "$@"
    exit 1
}

# shellcheck shell=bash
#
# Shared helpers: the run() wrapper that makes --dry-run structural, guarded
# filesystem mutation, network fetches, and small pure functions.
#
# Sourced, never executed.

: "${DRY_RUN:=false}"
: "${ASSUME_YES:=false}"

# Set by any function that changes system state. Callers use it to decide
# whether a service restart is warranted, so an unchanged re-run stays quiet.
: "${CHANGED:=false}"

# CHANGED answers "did this run change the host"; CHANGE_COUNT answers "how
# many times", which is what a module needs to know whether IT changed anything
# — a boolean that is already true from an earlier module cannot say.
: "${CHANGE_COUNT:=0}"
: "${HERMES_INSTALLER_RAN:=false}"
mark_changed() { CHANGED=true; CHANGE_COUNT=$(( CHANGE_COUNT + 1 )); }

# Bring a unit to "enabled and running the current configuration" and restart
# it ONLY if this module changed something. Three services used to restart on
# every run regardless — and each restart marked the run as changed, which then
# restarted the gateway too. A converged run must leave every process alone.
#
#   local before=$CHANGE_COUNT
#   ... writes ...
#   converge_unit "${unit}.service" "$before"
converge_unit() {
    local unit=$1 count_before=$2
    run systemctl enable "$unit"
    if (( CHANGE_COUNT != count_before )); then
        run systemctl restart "$unit"
    elif [[ $DRY_RUN != true ]] && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        log_info "${unit} is not running; starting it"
        run systemctl start "$unit"
        mark_changed
    else
        log_skip "${unit} already running with this configuration"
    fi
}

# A failure that must end the run, but only after the rest of it has happened.
#
# `die` is right when continuing would build on something broken. It is wrong
# when the broken thing is unrelated to what comes next: a mailbox the provider
# refuses has nothing to do with publishing the dashboard or installing the
# backup timer, and killing the run there leaves a host that is less finished
# than it needs to be — every re-run then has to get past the same wall to
# reach the work that was never blocked.
declare -ga DEFERRED_FAILURES=()

defer_failure() {
    DEFERRED_FAILURES+=("$*")
    log_error "$*"
    log_error "  The run continues; this is reported again at the end."
    return 0
}

# ---------------------------------------------------------------------------
# run — the single gate for every mutating command.
#
# Reads (test, stat, curl HEAD) run normally even under --dry-run; anything that
# changes the system goes through here. Routing every mutation through one
# wrapper is what keeps --dry-run honest as the code grows: a new mutation that
# forgets run() is visible in review as a bare command.
# ---------------------------------------------------------------------------
run() {
    if [[ $DRY_RUN == true ]]; then
        local rendered
        rendered=$(printf ' %q' "$@")
        log_info "[dry-run]${rendered}"
        return 0
    fi
    log_debug "exec:$(printf ' %q' "$@")"
    "$@"
}

# run_sh SCRIPT — for the rare case needing a pipeline or redirection.
# Prefer run(); this exists so such cases are still visible under --dry-run.
run_sh() {
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] sh -c $(printf '%q' "$1")"
        return 0
    fi
    log_debug "exec: sh -c $(printf '%q' "$1")"
    bash -c "$1"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# require_root REASON
#
# Under --dry-run this reports rather than refuses: a preview that itself
# demands root would have to be run privileged to find out whether running it
# privileged is a good idea.
require_root() {
    is_root && return 0
    if [[ ${DRY_RUN:-false} == true ]]; then
        log_warn "would require root: $*"
        return 0
    fi
    die "must run as root (or via sudo): $*"
}

# ---------------------------------------------------------------------------
# Interaction
#
# Reads from /dev/tty, not stdin: when a script is piped into a shell, stdin is
# the script text, and a bare read would consume it.
# ---------------------------------------------------------------------------

has_tty() { [[ -t 0 && -t 1 ]] || [[ -r /dev/tty ]]; }

confirm() {
    local prompt=$1 answer
    [[ $ASSUME_YES == true ]] && { log_debug "auto-confirmed: $prompt"; return 0; }
    has_tty || die "needs confirmation but no terminal is available: $prompt (pass --yes)"
    read -r -p "$prompt [y/N] " answer </dev/tty || return 1
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}

# ---------------------------------------------------------------------------
# Filesystem, guarded so a re-run converges instead of churning
# ---------------------------------------------------------------------------

# write_file PATH MODE OWNER < content
#
# Writes only when the content or metadata actually differs, so an unchanged
# re-run neither rewrites the file nor reports a change. The write is atomic:
# a temporary file in the same directory, then a rename.
write_file() {
    local path=$1 mode=$2 owner=${3:-}
    local content tmp
    content=$(cat)

    if [[ -f $path ]] && printf '%s' "$content" | cmp -s - "$path"; then
        local cur_mode
        cur_mode=$(stat -c '%a' "$path" 2>/dev/null || printf '')
        if [[ $cur_mode == "${mode#0}" || $cur_mode == "$mode" ]]; then
            log_skip "unchanged: $path"
            return 0
        fi
    fi

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write $path (mode $mode${owner:+, owner $owner})"
        mark_changed
        return 0
    fi

    tmp=$(mktemp "${path}.XXXXXX.tmp")
    printf '%s' "$content" >"$tmp"
    chmod "$mode" "$tmp"
    [[ -n $owner ]] && chown "$owner" "$tmp"
    mv -f "$tmp" "$path"
    mark_changed
    log_ok "wrote $path"
}

ensure_dir() {
    local path=$1 mode=${2:-0755} owner=${3:-}
    if [[ -d $path ]]; then
        log_skip "directory exists: $path"
        return 0
    fi
    # Built as an array rather than an unquoted ${owner:+...} expansion: IFS is
    # newline/tab here, so an unquoted expansion would collapse "-o u -g g" into
    # a single argument instead of four.
    local -a args=(install -d -m "$mode")
    [[ -n $owner ]] && args+=(-o "${owner%%:*}" -g "${owner##*:}")
    args+=("$path")
    run "${args[@]}"
    mark_changed
}

# ---------------------------------------------------------------------------
# Network
#
# One hardened fetch helper. --proto '=https' stops a redirect downgrading the
# transport; -f turns an error page into a non-zero exit instead of a file full
# of HTML. Curl options are never taken from the environment, which would be an
# injection point for --insecure.
# ---------------------------------------------------------------------------

fetch() {
    # The URL is the last argument by convention here; options precede it.
    local url="${*: -1}" proto
    proto=$(_curl_protocols "$url")
    curl --proto "$proto" --tlsv1.2 -fsSL \
         --retry 3 --retry-all-errors \
         --connect-timeout 10 --max-time 300 "$@"
}

# url_reachable URL — can we talk to this host at all?
#
# Any HTTP response counts, including 4xx: an API that answers "unauthorised"
# to an unauthenticated HEAD is reachable, which is the only thing a preflight
# egress check is asking. Requiring a 2xx here reports working endpoints as
# unreachable and sends the operator hunting for a firewall that is not there.
url_reachable() {
    [[ $(http_status "$1" -I) != 000 ]]
}

# http_status URL [curl args...] -> the status code, or 000 when unreachable.
# Which transports curl may use for a given URL.
#
# https everywhere, so a redirect cannot silently downgrade — except on
# loopback, where the bridge, the relay and the dashboard all speak plain http
# by design and there is no network for anyone to sit on. Pinning those to https
# too does not add security; it just makes every request fail before it is sent,
# and the caller then reports the service as down.
_curl_protocols() {
    local url=${1,,} rest host
    if [[ $url != http://* ]]; then printf '=https'; return 0; fi
    rest=${url#http://}
    rest=${rest%%/*}
    # A bracketed IPv6 literal carries colons of its own, so the port cannot be
    # split off before the brackets are.
    if [[ $rest == \[*\]* ]]; then
        host=${rest%%\]*}]
    else
        host=${rest%%:*}
    fi
    # https everywhere it could matter. The exceptions are addresses that are
    # not on the internet at all: loopback, and the private ranges this
    # provisioner publishes the dashboard on by configuration. The rule exists
    # so a redirect cannot silently downgrade a transfer to plaintext — a check
    # aimed at an address we ourselves configured for plain http is not that,
    # and pinning it to https only makes every such check fail before it is
    # sent, which then reads as "the service is down".
    case $host in
        localhost|'[::1]'|127.*)              printf '=http,https' ;;
        10.*|192.168.*|169.254.*)             printf '=http,https' ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) printf '=http,https' ;;
        *)                                    printf '=https' ;;
    esac
}

http_status() {
    local url=$1; shift
    local code proto
    proto=$(_curl_protocols "$url")
    # curl already prints 000 on a connection failure, so a fallback appended to
    # its output would produce "000000". Capture, then substitute only if empty.
    code=$(curl --proto "$proto" -s -o /dev/null -w '%{http_code}' \
                --connect-timeout 10 --max-time 30 "$@" "$url" 2>/dev/null) || true
    printf '%s' "${code:-000}"
}

# retry ATTEMPTS DELAY -- COMMAND...
retry() {
    local attempts=$1 delay=$2; shift 2
    [[ ${1:-} == -- ]] && shift
    local n=1
    until "$@"; do
        if (( n >= attempts )); then
            log_error "failed after ${attempts} attempts: $1"
            return 1
        fi
        log_warn "attempt ${n}/${attempts} failed, retrying in ${delay}s: $1"
        sleep "$delay"
        n=$(( n + 1 ))
    done
}

# ---------------------------------------------------------------------------
# Pure helpers — unit-tested directly
# ---------------------------------------------------------------------------

# detect_arch -> amd64 | arm64, or fails loudly on anything else.
# An allowlist, not a passthrough: guessing at an unknown architecture produces
# a broken install rather than an error.
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *)             die "unsupported architecture: $(uname -m)" ;;
    esac
}

# os_release_value KEY -> value from /etc/os-release
os_release_value() {
    local key=$1
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    (. /etc/os-release && printf '%s' "${!key:-}")
}

# distro_codename -> the upstream codename.
# Derivatives set VERSION_CODENAME to their own name but keep UBUNTU_CODENAME
# pointing at the upstream release, which is the one package repositories know.
distro_codename() {
    local c
    c=$(os_release_value UBUNTU_CODENAME) || true
    [[ -n ${c:-} ]] || c=$(os_release_value VERSION_CODENAME) || true
    printf '%s' "${c:-}"
}

# version_ge A B -> true when A >= B, using dpkg ordering where available.
version_ge() {
    if have_cmd dpkg; then
        dpkg --compare-versions "$1" ge "$2"
    else
        [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
    fi
}

# is_true VALUE — accepts the spellings people actually write in config files.
is_true() {
    case "${1,,}" in
        true|yes|on|1) return 0 ;;
        *)             return 1 ;;
    esac
}

# join_by SEP ITEM...
join_by() {
    local sep=$1; shift
    local out=""
    local item
    for item in "$@"; do
        out+="${out:+$sep}${item}"
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Mutual exclusion — two concurrent runs would race on apt, systemd and the
# agent's own data directory. The vendor installer takes no lock of its own.
# ---------------------------------------------------------------------------

acquire_lock() {
    local lockfile=${1:-/var/lock/hermes-provisioner.lock}

    # `exec` with redirections and no command applies them to THIS shell, for
    # the rest of its life. A 2>/dev/null meant to silence one failed open
    # therefore silences every log line the run would have written — every
    # log_* writes to stderr — and the run goes dark from here on. Decide
    # where the lock lives with an ordinary command, whose redirection is
    # scoped to itself, and give exec nothing to swallow.
    if ! : >>"$lockfile" 2>/dev/null; then
        lockfile="${TMPDIR:-/tmp}/hermes-provisioner.lock"
    fi
    exec {_LOCK_FD}>"$lockfile"
    flock -n "$_LOCK_FD" || die "another provisioner run holds $lockfile"
    log_debug "lock acquired: $lockfile"
}

# ---------------------------------------------------------------------------
# The bot's own version.
#
# bot/ holds the code that runs as part of the agent (the bridge, the MCP
# assistants, the Teams app manifest). It is versioned separately from the
# installer: bot/VERSION is the single source, bot/release.sh moves it, and the
# installer stamps it into what it installs so a host can say which bot it runs.
# ---------------------------------------------------------------------------
bot_version() {
    local f="${SCRIPT_DIR}/bot/VERSION" v
    [[ -r $f ]] || die "bot/VERSION is missing; the repository is incomplete"
    v=$(tr -d '[:space:]' <"$f")
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bot/VERSION must be MAJOR.MINOR.PATCH, got '${v}'"
    printf '%s' "$v"
}

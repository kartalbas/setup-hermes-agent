#!/usr/bin/env bash
#
# End-to-end acceptance: install -> re-install -> uninstall.
#
# This is the test that decides whether the provisioner is actually idempotent.
# Everything else checks pieces; this one checks the claim.
#
#   1. install                  the service comes up
#   2. install again            NOTHING changes, and the vendor installer is
#                               not even invoked (the revision is already right)
#   3. uninstall                unit, drop-ins and code are gone; state remains
#   4. uninstall again          succeeds, changing nothing
#
# THIS IS DESTRUCTIVE. It installs and removes a real service on the host it
# runs on. Run it on a disposable machine or immediately after a snapshot, never
# on a host you would mind rebuilding — and it refuses to start without an
# explicit acknowledgement for exactly that reason.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PASSED=0
FAILED=0

red()   { [[ -t 1 ]] && printf '\033[0;31m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
green() { [[ -t 1 ]] && printf '\033[0;32m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
step()  { printf '\n== %s\n' "$*"; }

check() {
    local what=$1; shift
    if "$@"; then
        green "  ok    ${what}"
        PASSED=$(( PASSED + 1 ))
    else
        red   "  FAIL  ${what}"
        FAILED=$(( FAILED + 1 ))
    fi
}

check_not() {
    local what=$1; shift
    if "$@"; then
        red   "  FAIL  ${what}"
        FAILED=$(( FAILED + 1 ))
    else
        green "  ok    ${what}"
        PASSED=$(( PASSED + 1 ))
    fi
}

usage() {
    cat <<'HELPTEXT'
End-to-end acceptance test — DESTRUCTIVE.

Installs and removes a real service on this host. Run it on a disposable
machine, or immediately after taking a snapshot you are willing to roll back to.

    tests/acceptance.sh --i-understand-this-is-destructive

Options:
    --config FILE     configuration to test with (default: config/hermes.conf)
    --keep            skip the uninstall phase, leaving the install in place
    -h, --help        this text
HELPTEXT
}

CONFIG="${REPO_ROOT}/config/hermes.conf"
CONFIRMED=false
KEEP=false

while (( $# )); do
    case $1 in
        --i-understand-this-is-destructive) CONFIRMED=true; shift ;;
        --config) CONFIG=$2; shift 2 ;;
        --keep)   KEEP=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ $CONFIRMED != true ]]; then
    usage >&2
    red $'\nRefusing to run without --i-understand-this-is-destructive.'
    exit 2
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || { red "must run as root"; exit 1; }
[[ -f $CONFIG ]] || { red "no configuration at ${CONFIG}"; exit 1; }

# Read the settings the assertions need, without executing the rest of the run.
# shellcheck disable=SC1090
source "$CONFIG"
SERVICE_NAME=${SERVICE_NAME:-hermes-gateway}
HERMES_HOME=${HERMES_HOME:-}
STATE_DIR=${PROVISIONER_STATE_DIR:-/var/lib/hermes-provisioner}

INSTALL="${REPO_ROOT}/install.sh --config ${CONFIG} --yes"
LOG_DIR=$(mktemp -d)
trap 'printf "\nlogs: %s\n" "$LOG_DIR"' EXIT

service_active()   { systemctl is-active --quiet "${SERVICE_NAME}.service"; }
unit_exists()      { [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; }
dropin_exists()    { [[ -f "/etc/systemd/system/${SERVICE_NAME}.service.d/10-provisioner.conf" ]]; }
user_unit_exists() {
    local home; home=$(getent passwd "${SERVICE_USER:-root}" 2>/dev/null | cut -d: -f6 || printf '')
    [[ -n $home && -f "${home}/.config/systemd/user/${SERVICE_NAME}.service" ]]
}
state_present()    { [[ -n $HERMES_HOME && -d $HERMES_HOME ]]; }

# ---------------------------------------------------------------------------
step "1/4  install"
# ---------------------------------------------------------------------------
$INSTALL >"${LOG_DIR}/install-1.log" 2>&1 || {
    red "install failed; see ${LOG_DIR}/install-1.log"
    tail -30 "${LOG_DIR}/install-1.log"
    exit 1
}
check "service is active"                service_active
check "system unit exists"               unit_exists
check "drop-in was written"              dropin_exists
check "revision was recorded"            test -f "${STATE_DIR}/revision"
check_not "no user-scope unit was left behind" user_unit_exists

# ---------------------------------------------------------------------------
step "2/4  install again — this is the idempotency claim"
# ---------------------------------------------------------------------------
UNIT_MTIME_BEFORE=$(stat -c '%Y' "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || printf 0)
START_TIME_BEFORE=$(systemctl show -p ActiveEnterTimestampMonotonic --value "${SERVICE_NAME}.service" 2>/dev/null || printf 0)

$INSTALL >"${LOG_DIR}/install-2.log" 2>&1 || {
    red "second install failed; see ${LOG_DIR}/install-2.log"
    tail -30 "${LOG_DIR}/install-2.log"
    exit 1
}

UNIT_MTIME_AFTER=$(stat -c '%Y' "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || printf 0)
START_TIME_AFTER=$(systemctl show -p ActiveEnterTimestampMonotonic --value "${SERVICE_NAME}.service" 2>/dev/null || printf 0)

check "the run reports no change" \
    grep -q "already in the desired state" "${LOG_DIR}/install-2.log"

# The pin guard: once the checkout matches the recorded revision, the vendor
# installer must not run at all. It is not idempotent, and running it again is
# what silently moves the checkout off the pinned commit.
check "the vendor installer was skipped" \
    grep -q "skipping the vendor installer" "${LOG_DIR}/install-2.log"

check "the service was not restarted" \
    test "$START_TIME_BEFORE" = "$START_TIME_AFTER"
check "the unit file was not rewritten" \
    test "$UNIT_MTIME_BEFORE" = "$UNIT_MTIME_AFTER"
check "service is still active"          service_active

if [[ $KEEP == true ]]; then
    step "stopping here (--keep)"
    printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
    exit $(( FAILED > 0 ))
fi

# ---------------------------------------------------------------------------
step "3/4  uninstall — state must survive"
# ---------------------------------------------------------------------------
HAD_STATE=false
state_present && HAD_STATE=true

"${REPO_ROOT}/install.sh" --config "$CONFIG" --yes --uninstall \
    >"${LOG_DIR}/uninstall-1.log" 2>&1 || {
    red "uninstall failed; see ${LOG_DIR}/uninstall-1.log"
    tail -30 "${LOG_DIR}/uninstall-1.log"
    exit 1
}

check_not "unit is gone"                 unit_exists
check_not "drop-in directory is gone"    test -d "/etc/systemd/system/${SERVICE_NAME}.service.d"
check_not "service is no longer active"  service_active
check_not "unit is not left in a failed state" \
    systemctl is-failed --quiet "${SERVICE_NAME}.service"

# Without --purge the agent's accumulated state is the one thing that must not
# be removed: conversations, memory and learned skills are not reproducible.
if [[ $HAD_STATE == true ]]; then
    check "agent state was preserved"    state_present
fi

# ---------------------------------------------------------------------------
step "4/4  uninstall again — must succeed and change nothing"
# ---------------------------------------------------------------------------
"${REPO_ROOT}/install.sh" --config "$CONFIG" --yes --uninstall \
    >"${LOG_DIR}/uninstall-2.log" 2>&1
check "a second uninstall succeeds" test $? -eq 0

printf '\n'
if (( FAILED )); then
    red "${PASSED} passed, ${FAILED} failed"
    exit 1
fi
green "${PASSED} passed, 0 failed"

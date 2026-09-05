# shellcheck shell=bash
#
# Shared setup for the unit tests.
#
# The libraries are sourceable without side effects — definitions only — which
# is what lets them be tested directly rather than through the entry point.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# load_libs [name ...]
#
# Sources every library, or only the named ones. Loading all of them is closest
# to how install.sh runs and catches cross-library breakage; loading a subset is
# useful when a test wants to stub something a later library would overwrite.
# NOTE ON `run`
#
# src/10-util.sh defines a function called run() — the wrapper that makes
# --dry-run structural. It shadows bats' own `run`, and a shadowed `run` sets
# neither $status nor $output, so every assertion silently compares against an
# empty string and fails while the expected value is plainly visible in the
# output. Rescue bats' version under a second name before loading the libraries,
# and use bats_run in tests that need it.
load_libs() {
    local lib
    if declare -F run >/dev/null 2>&1 && ! declare -F bats_run >/dev/null 2>&1; then
        eval "bats_run() $(declare -f run | tail -n +2)"
    fi
    if (( $# )); then
        for lib in "$@"; do
            # shellcheck disable=SC1090
            source "${REPO_ROOT}/libs/${lib}"
        done
    else
        for lib in "${REPO_ROOT}"/libs/[0-9][0-9]-*.sh; do
            # shellcheck disable=SC1090
            source "$lib"
        done
    fi
}

# A secrets file with the right mode, in a directory bats cleans up.
make_secrets_file() {
    local path="${BATS_TEST_TMPDIR}/secrets.env"
    cat >"$path"
    chmod 0600 "$path"
    printf '%s' "$path"
}

# Quiet the logger so assertions read the values under test, not the noise.
silence_logs() {
    LOG_LEVEL=error
}

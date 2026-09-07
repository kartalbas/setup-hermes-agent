#!/usr/bin/env bash
#
# Everything that can be checked without touching the host.
#
# The destructive end-to-end cycle is deliberately not included — see
# tests/acceptance.sh, which installs and removes a real service and must be
# invoked on purpose.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

FAILED=0

red()   { [[ -t 1 ]] && printf '\033[0;31m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
green() { [[ -t 1 ]] && printf '\033[0;32m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
amber() { [[ -t 1 ]] && printf '\033[0;33m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
step()  { printf '\n== %s\n' "$*"; }

step "syntax"
for f in install.sh libs/*.sh tests/*.sh bot/ops/opsctl bot/ops/apply.sh bot/release.sh; do
    bash -n "$f" || { red "  parse error: $f"; FAILED=1; }
done
green "  every script parses"

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -S style install.sh libs/*.sh tests/*.sh bot/ops/opsctl bot/ops/apply.sh; then
        green "  clean"
    else
        red "  findings above"
        FAILED=1
    fi
else
    amber "  not installed — apt-get install shellcheck"
fi

step "unit tests"
if command -v bats >/dev/null 2>&1; then
    bats tests/bats/ || FAILED=1
else
    amber "  bats not installed — apt-get install bats"
fi

step "python unit tests (bot/mcp)"
if python3 -m unittest discover -s tests/python -t . -q 2>&1 | tail -3; then
    :
else
    FAILED=1
fi

step "site-agnosticism"
tests/agnostic.sh || FAILED=1

step "dry run against the example configuration"
# The examples carry no secrets, so this exercises argument parsing, library
# loading and the validator's error path rather than a full plan.
if ./install.sh --dry-run --config config/hermes.conf.example \
                --channels config/channels.conf.example >/dev/null 2>&1; then
    amber "  example config validated (unexpected — it has no SECRETS_FILE)"
else
    green "  example config is correctly rejected as incomplete"
fi

printf '\n'
if (( FAILED )); then
    red "FAILED"
    exit 1
fi
green "all checks passed"
printf '\nThe destructive end-to-end cycle is separate:\n'
printf '  sudo tests/acceptance.sh --i-understand-this-is-destructive\n'

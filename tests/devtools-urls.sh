#!/usr/bin/env bash
#
# Resolve every download URL in the tool catalogue and check that it still
# answers, without installing anything.
#
# NOT part of tests/run.sh: it needs the network and spends one GitHub API call
# per unpinned tool against a 60-per-hour budget. Run it when the catalogue
# changes, or when a tool fails to install. Set GITHUB_TOKEN to avoid the limit.
#
#   tests/devtools-urls.sh
#
# A renamed release asset is the usual cause of a 404 here — upstream projects
# rename them without warning, and the failure otherwise only shows up mid-run
# on a machine that does not yet have the tool.
set -uo pipefail
cd "${1:-$(dirname "$0")/..}" || exit 1
# Read by the libraries below, which shellcheck cannot follow through a glob.
# shellcheck disable=SC2034
DRY_RUN=false CHANGED=false LOG_LEVEL=error
# shellcheck source=/dev/null
. libs/00-log.sh; . libs/10-util.sh; . config/install.conf

# Replace the three fetchers with a URL reporter.
_dt_fetch_archive() { printf '%s\n' "$1"; }
_dt_fetch_gz()      { printf '%s\n' "$1"; }
_dt_fetch_binary()  { printf '%s\n' "$1"; }
# shellcheck source=/dev/null
. libs/58-devtools.sh

IFS=$' \t\n'
fail=0
for t in $DEVTOOLS_INSTALL; do
    _dt_is_apt "$t" && continue
    url=$(_dt_install "$t" "" 2>/dev/null | grep -m1 '^https://')
    if [[ -z $url ]]; then
        printf '  %-16s %s\n' "$t" "no URL resolved (script or apt path)"
        continue
    fi
    code=$(curl -o /dev/null -sIL -w '%{http_code}' --max-time 25 "$url")
    if [[ $code == 200 ]]; then
        printf '  %-16s ok   %s\n' "$t" "${url##*/}"
    else
        printf '  %-16s %s  %s\n' "$t" "$code" "$url"
        fail=$(( fail + 1 ))
    fi
done
printf '\n%d broken\n' "$fail"

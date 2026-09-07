#!/usr/bin/env bash
#
# The root side of `opsctl apply`: started by hermes-ops-apply.path when the
# Admin bot has written an apply request, it runs the installer from the
# repository with the requested modules and leaves a log the bot can read.
#
# It runs as root because the installer needs root; the bots themselves run
# under NoNewPrivileges and cannot sudo — the request file is the one narrow
# door, and what comes through it is always the same command.
set -Eeuo pipefail

: "${OPS_REPO:?}" "${OPS_STATE:?}"
: "${OPS_GROUP:=$(stat -c %G "$OPS_STATE" 2>/dev/null || echo root)}"

req="${OPS_STATE}/apply.request"
[[ -f $req ]] || exit 0
mods=$(tr -d '[:space:]' <"$req")
rm -f "$req"

ts=$(date +%Y%m%d-%H%M%S)
log="${OPS_STATE}/apply-${ts}.log"
: >"$log"; chgrp "$OPS_GROUP" "$log" 2>/dev/null || true; chmod 0640 "$log"
printf '%s modules=%s state=running\n' "$(date -Is)" "${mods:-all}" >"${OPS_STATE}/apply-last"

cd "$OPS_REPO"
rc=0
if [[ -n $mods ]]; then ./install.sh --only "$mods" >>"$log" 2>&1 || rc=$?
else ./install.sh >>"$log" 2>&1 || rc=$?; fi
printf 'exit=%s\n' "$rc" >>"$log"
printf '%s modules=%s state=finished exit=%s log=%s\n' "$(date -Is)" "${mods:-all}" "$rc" "$log" >"${OPS_STATE}/apply-last"
chgrp "$OPS_GROUP" "${OPS_STATE}/apply-last" 2>/dev/null || true; chmod 0640 "${OPS_STATE}/apply-last"
exit "$rc"

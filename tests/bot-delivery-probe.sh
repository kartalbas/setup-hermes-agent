#!/usr/bin/env bash
#
# Prove that the Bot Framework can deliver to this host — without Teams.
#
# Direct Line is a Bot Framework channel like Teams is; an activity posted to
# it goes through Microsoft's delivery path to the bot's registered endpoint:
# Azure -> Cloudflare edge (TLS) -> tunnel -> gateway -> Teams SDK (JWT). The
# gateway then rejects the probe identity on the allowlist, which is the point:
# "Unauthorized user: probe () on teams" in the gateway log means every hop
# before the allowlist worked.
#
# If this passes and a Teams message still does not arrive, the problem is in
# Teams' binding to the bot (usually a chat still attached to a deleted bot
# resource), not in anything on this host or in Azure.
#
# Needs: `az login` as the account running this; the bot's name and resource
# group from config/hermes.conf; the tunnel's metrics endpoint.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source config/hermes.conf
export AZURE_CORE_ONLY_SHOW_ERRORS=true

: "${AZURE_RESOURCE_GROUP:?set in config/hermes.conf}"
# Which bot: the key given as $1, or every key in BOTS; the Azure Bot is
# <BOT_SERVICE_PREFIX>-<key> unless BOT_<KEY>_AZURE_NAME says otherwise.
keys=${1:-${BOTS:?set BOTS in config/hermes.conf, or pass a bot key}}
metrics="http://127.0.0.1:20241/metrics"
rc=0
for key in $keys; do
upper=$(tr '[:lower:]' '[:upper:]' <<<"$key")
name_var="BOT_${upper}_AZURE_NAME"; AZURE_BOT_NAME=${!name_var:-${BOT_SERVICE_PREFIX:-agent}-${key}}
unit_var="BOT_${upper}_SERVICE";     unit=${!unit_var:-${BOT_SERVICE_PREFIX:-agent}-${key}}
echo "== ${key}: bot ${AZURE_BOT_NAME}, unit ${unit}"
count() { curl -s --max-time 5 "$metrics" | awk '/^cloudflared_tunnel_total_requests/ {print $2}'; }

secret=$(az bot directline show -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_BOT_NAME" --with-secrets true \
           --query 'properties.properties.sites[0].key' -o tsv 2>/dev/null) ||
    { echo "cannot read the Direct Line secret — az login, and the bot must have the Direct Line channel"; exit 1; }

before=$(count)
conv=$(curl -sS -X POST -H "Authorization: Bearer $secret" \
         https://directline.botframework.com/v3/directline/conversations | jq -r '.conversationId // empty')
[[ -n $conv ]] || { echo "Direct Line refused to open a conversation"; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $secret" -H 'Content-Type: application/json' \
         -d '{"type":"message","from":{"id":"probe"},"text":"ping"}' \
         "https://directline.botframework.com/v3/directline/conversations/${conv}/activities")
sleep 8
after=$(count)

printf 'activity posted: HTTP %s\ntunnel requests: %s -> %s\n' "$code" "${before:-?}" "${after:-?}"
if [[ -n $before && -n $after ]] && (( after > before )); then
    echo "DELIVERED: the Bot Framework reached this host through the tunnel"
    sudo journalctl -u "$unit" --since '-40 sec' --no-pager 2>/dev/null \
        | grep -iE 'Unauthorized user: probe|teams' | tail -2 | sed 's/^/  gateway: /'
else
    echo "NOT DELIVERED: the counter did not move — check the edge certificate, the tunnel and the bot endpoint"
    rc=1
fi
done
exit $rc

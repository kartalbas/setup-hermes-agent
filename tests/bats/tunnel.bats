#!/usr/bin/env bats
#
# The tunnel's public surface is derived from the bot list: one hostname per
# bot to its own loopback port, one path, everything else 404.

setup() {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT
    TUNNEL_ZONE=example.com TUNNEL_INGRESS_PATH=/api/messages TUNNEL_INGRESS_TARGET=http://127.0.0.1:3978
    TUNNEL_HOSTNAME=agent.example.com
    HERMES_HOME=/home/agent/.hermes
}

@test "without bots the single hostname is published" {
    BOTS=""; config_defaults
    [ "$(tunnel_hostnames)" = "agent.example.com" ]
    rules=$(tunnel_ingress_rules | jq -sc .)
    [ "$(jq -r 'length' <<<"$rules")" = 2 ]
    [ "$(jq -r '.[0].hostname' <<<"$rules")" = agent.example.com ]
    [ "$(jq -r '.[1].service' <<<"$rules")" = http_status:404 ]
}

@test "with bots every bot gets its hostname and its own port, and 404 closes the list" {
    BOTS="secretary search news" BOT_PREFIX=Acme; config_defaults
    [ "$(tunnel_hostnames | tr '\n' ' ')" = "secretary.example.com search.example.com news.example.com " ]
    rules=$(tunnel_ingress_rules | jq -sc .)
    [ "$(jq -r 'length' <<<"$rules")" = 4 ]
    [ "$(jq -r '.[1].hostname' <<<"$rules")" = search.example.com ]
    [ "$(jq -r '.[1].service' <<<"$rules")" = http://127.0.0.1:3979 ]
    [ "$(jq -r '.[1].path' <<<"$rules")" = /api/messages ]
    [ "$(jq -r '.[3].service' <<<"$rules")" = http_status:404 ]
}

@test "the public site adds its hostname and a whole-host rule before the 404" {
    BOTS="secretary" BOT_PREFIX=Acme SITE_ENABLED=true SITE_OWNER=Acme SITE_CONTACT=a@example.com; config_defaults
    [ "$(tunnel_hostnames | tr '\n' ' ')" = "secretary.example.com assistant.example.com " ]
    rules=$(tunnel_ingress_rules | jq -sc .)
    [ "$(jq -r '.[1].hostname' <<<"$rules")" = assistant.example.com ]
    [ "$(jq -r '.[1].service' <<<"$rules")" = http://127.0.0.1:8081 ]
    [ "$(jq -r '.[1] | has("path")' <<<"$rules")" = false ]
    [ "$(jq -r '.[2].service' <<<"$rules")" = http_status:404 ]
}

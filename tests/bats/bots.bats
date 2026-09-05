#!/usr/bin/env bats
#
# The bot layer: one word in BOTS is a complete bot, every field has a derived
# default, and the validation catches what would only fail at runtime.

setup() {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT
    TUNNEL_ZONE=example.com
    HERMES_HOME=/home/agent/.hermes
    BOTS="secretary search news"
    BOT_PREFIX="Acme"
    BOT_SERVICE_PREFIX="acme"
    config_defaults
}

@test "fields derive from the key" {
    [ "$(bot_field search NAME)" = "Search" ]
    [ "$(bot_field search DISPLAY_NAME)" = "Acme Search" ]
    [ "$(bot_field search PORT)" = 3979 ]
    [ "$(bot_field news PORT)" = 3980 ]
    [ "$(bot_field news HOSTNAME)" = "news.example.com" ]
    [ "$(bot_field news SERVICE)" = "acme-news" ]
    [ "$(bot_field news TEAMS_CLIENT_ID_VAR)" = "TEAMS_NEWS_CLIENT_ID" ]
    [ "$(bot_field news CHANNELS)" = "teams" ]
    [ "$(bot_home news)" = "/home/agent/.hermes/profiles/news" ]
}

@test "a configured field wins over its default" {
    BOT_SECRETARY_PORT=4000 BOT_SECRETARY_CHANNELS="teams email" BOT_SECRETARY_TEAMS_CLIENT_ID_VAR=TEAMS_CLIENT_ID
    [ "$(bot_field secretary PORT)" = 4000 ]
    bot_has_channel secretary email
    ! bot_has_channel news email
    [ "$(bot_field secretary TEAMS_CLIENT_ID_VAR)" = TEAMS_CLIENT_ID ]
}

@test "bot_context exports the bot and points the config helpers at its profile" {
    bot_context news
    [ "$BOT_KEY" = news ]
    [ "$BOT_DISPLAY_NAME" = "Acme News" ]
    [ "$HERMES_CONFIG_HOME" = "/home/agent/.hermes/profiles/news" ]
    [ "$(yaml_config_path)" = "/home/agent/.hermes/profiles/news/config.yaml" ]
    [ "$(_env_file)" = "/home/agent/.hermes/profiles/news/.env" ]
    bot_context_end
    [ "$HERMES_CONFIG_HOME" = "$HERMES_HOME" ]
    [ "$(yaml_config_path)" = "/home/agent/.hermes/config.yaml" ]
}

@test "every configured bot has a role file in the repository" {
    local k
    for k in $BOTS; do [ -f "$(bot_role_file "$k")" ]; done
}

@test "validation catches duplicate ports, unknown channels and servers, and two mailboxes" {
    _invalid=(); BOT_SEARCH_PORT=3978; _bots_validate; [ "${#_invalid[@]}" -eq 1 ]; unset BOT_SEARCH_PORT
    _invalid=(); BOT_NEWS_CHANNELS="teams slack"; _bots_validate; [ "${#_invalid[@]}" -eq 1 ]; unset BOT_NEWS_CHANNELS
    _invalid=(); BOT_NEWS_MCP="m365"; _bots_validate; [ "${#_invalid[@]}" -eq 1 ]; unset BOT_NEWS_MCP
    _invalid=(); BOT_NEWS_CHANNELS="teams email" BOT_SEARCH_CHANNELS="teams email"; _bots_validate; [ "${#_invalid[@]}" -eq 1 ]
    unset BOT_NEWS_CHANNELS BOT_SEARCH_CHANNELS
    _invalid=(); BOTS="Bad-Key"; _bots_validate; [ "${#_invalid[@]}" -ge 1 ]
    _invalid=(); BOTS="secretary search news"; _bots_validate; [ "${#_invalid[@]}" -eq 0 ]
}

@test "no bots means no constraints" {
    BOTS=""; _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 0 ]; [ "$(bot_count)" -eq 0 ]
}

@test "a bot unit points at the bot's profile and carries the watchdog" {
    DRY_RUN=false SERVICE_USER=$(id -un) SERVICE_GROUP=$(id -gn) SERVICE_WATCHDOG_SECONDS=90
    local tmp; tmp=$(mktemp -d)
    hermes_install_dir() { printf '%s/agent' "$tmp"; }
    service_unit_path() { printf '%s/unit.service' "$tmp"; }
    run() { "$@"; }   # daemon-reload is not for a test host
    systemctl() { :; }
    bot_context news
    _service_write_bot_unit
    grep -q '^Environment="HERMES_HOME=/home/agent/.hermes/profiles/news"' "$tmp/unit.service"
    grep -q '^WorkingDirectory=/home/agent/.hermes/profiles/news' "$tmp/unit.service"
    grep -q '^Type=notify' "$tmp/unit.service"
    grep -q '^WatchdogSec=90s' "$tmp/unit.service"
    grep -q '^Description=Acme News bot' "$tmp/unit.service"
    grep -q '^SyslogIdentifier=acme-news' "$tmp/unit.service"
    rm -rf "$tmp"
}

@test "SOUL.md starts with the configured name and forbids the vendor's" {
    bot_context news
    out=$(profile_soul_text "$(bot_role_file news)")
    [[ $out == "# Acme News"* ]]
    [[ $out == *'Your name is **Acme News**'* ]]
    [[ $out == *'never call'*'"Hermes"'* ]]
    [[ $out == *"You are a news desk"* ]]
    ! grep -q '^# News$' <<<"$out"
}

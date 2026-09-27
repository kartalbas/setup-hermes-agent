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
    _invalid=(); BOT_NEWS_CHANNELS="teams email" BOT_SEARCH_CHANNELS="teams email"; _bots_validate; [ "${#_invalid[@]}" -ge 1 ]   # two INBOX readers
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

@test "a bot's own model replaces endpoint 1 for its pass and is restored afterwards" {
    LLM_ENDPOINT_COUNT=1 LLM_STRATEGY=single LLM_ENDPOINT_1_PROVIDER=custom LLM_ENDPOINT_1_NAME=bridge
    LLM_ENDPOINT_1_BASE_URL=http://127.0.0.1:8787/v1 LLM_ENDPOINT_1_MODEL=gemini LLM_ENDPOINT_1_TOKEN_VAR=""
    LLM_REASONING_FIELD="" LLM_CONTEXT_WINDOW=512000
    BOT_SECRETARY_LLM_MODEL=kimi-k3 BOT_SECRETARY_LLM_NAME=kimi BOT_SECRETARY_LLM_BASE_URL=https://api.example.com/v1
    BOT_SECRETARY_LLM_TOKEN_VAR=KIMI_API_KEY BOT_SECRETARY_LLM_REASONING_FIELD=reasoning_content
    bot_llm_apply secretary
    [ "$LLM_ENDPOINT_1_MODEL" = kimi-k3 ]; [ "$LLM_ENDPOINT_1_NAME" = kimi ]; [ "$LLM_ENDPOINT_1_TOKEN_VAR" = KIMI_API_KEY ]
    [ "$LLM_REASONING_FIELD" = reasoning_content ]
    bot_llm_restore
    [ "$LLM_ENDPOINT_1_MODEL" = gemini ]; [ "$LLM_ENDPOINT_1_NAME" = bridge ]; [ "$LLM_REASONING_FIELD" = "" ]
    bot_llm_apply news            # no own model: nothing changes
    [ "$LLM_ENDPOINT_1_MODEL" = gemini ]
    bot_llm_restore
}

@test "a bot model needs a base url for a custom provider and a present key" {
    _invalid=(); BOT_NEWS_LLM_MODEL=x; _bots_validate; [ "${#_invalid[@]}" -ge 1 ]; unset BOT_NEWS_LLM_MODEL
    _invalid=(); BOT_NEWS_LLM_MODEL=x BOT_NEWS_LLM_BASE_URL=https://api.example.com/v1 BOT_NEWS_LLM_TOKEN_VAR=NOPE
    _bots_validate; [ "${#_invalid[@]}" -eq 1 ]
    unset BOT_NEWS_LLM_MODEL BOT_NEWS_LLM_BASE_URL BOT_NEWS_LLM_TOKEN_VAR
}

@test "session reset specs render to the agent's block and bad ones are rejected" {
    [ "$(session_reset_yaml none)" = $'session_reset:\n  mode: none' ]
    [ "$(session_reset_yaml daily@4)" = $'session_reset:\n  mode: daily\n  at_hour: 4' ]   # agnostic-ok
    [ "$(session_reset_yaml idle@90)" = $'session_reset:\n  mode: idle\n  idle_minutes: 90' ]   # agnostic-ok
    ! session_reset_yaml weekly
    _invalid=(); _check_session_reset X daily@24; [ "${#_invalid[@]}" -eq 1 ]   # agnostic-ok
    _invalid=(); _check_session_reset X idle@0; [ "${#_invalid[@]}" -eq 1 ]   # agnostic-ok
    _invalid=(); _check_session_reset X daily@4; [ "${#_invalid[@]}" -eq 0 ]   # agnostic-ok
    AGENT_SESSION_RESET=daily@4 BOT_NEWS_SESSION_RESET=idle@60   # agnostic-ok
    [ "$(bot_field secretary SESSION_RESET)" = daily@4 ]   # agnostic-ok
    [ "$(bot_field news SESSION_RESET)" = idle@60 ]   # agnostic-ok
}

@test "mail folders derive from alias and catch-all, and INBOX has one reader" {
    BOT_SECRETARY_CHANNELS="teams email" BOT_SECRETARY_MAIL_ALIAS=secretary@example.com BOT_SECRETARY_MAIL_CATCH_ALL=true
    BOT_SEARCH_CHANNELS="teams email" BOT_SEARCH_MAIL_ALIAS=search@example.com
    BOT_NEWS_CHANNELS="teams email" BOT_NEWS_MAIL_ALIAS=news@example.com
    [ "$(bot_field secretary MAIL_FOLDER)" = INBOX ]
    [ "$(bot_field search MAIL_FOLDER)" = Search ]
    [ "$(bot_field news MAIL_FOLDER)" = News ]
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 0 ]
    unset BOT_NEWS_MAIL_ALIAS                       # news would read INBOX too
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -ge 1 ]
}

@test "the carried adapter patch makes the folder configurable, once" {
    local f; f=$(mktemp)
    printf 'import imaplib\n\ndef a(imap):\n    imap.select("INBOX")\n\ndef b(imap):\n    imap.select("INBOX")\n' >"$f"
    hermes_patch_email_folder_file "$f"
    [ "$(grep -c 'os.environ.get("EMAIL_IMAP_FOLDER", "INBOX")' "$f")" -eq 2 ]
    grep -q '^import os' "$f"
    bats_run hermes_patch_email_folder_file "$f"
    [ "$status" -eq 3 ]
    rm -f "$f"
}

@test "a delegation endpoint renders the bridge without a key and a hosted provider by name" {
    BOTS="secretary" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    LLM_ENDPOINT_COUNT=2
    LLM_ENDPOINT_1_PROVIDER=custom LLM_ENDPOINT_1_NAME=bridge LLM_ENDPOINT_1_BASE_URL=http://127.0.0.1:8787/v1 LLM_ENDPOINT_1_MODEL=fast LLM_ENDPOINT_1_TOKEN_VAR=""
    LLM_ENDPOINT_2_PROVIDER=deepseek LLM_ENDPOINT_2_NAME=deepseek LLM_ENDPOINT_2_BASE_URL="" LLM_ENDPOINT_2_MODEL=deepseek-chat LLM_ENDPOINT_2_TOKEN_VAR=DEEPSEEK_API_KEY
    BOT_SECRETARY_DELEGATION_ENDPOINT=1
    out=$(_delegation_fragment secretary)
    [[ $out == *'model: "fast"'* && $out == *'base_url: "http://127.0.0.1:8787/v1"'* && $out == *'api_key: "bridge-does-not-check-keys"'* ]]
    [[ $out == *'provider: ""'* ]]
    BOT_SECRETARY_DELEGATION_ENDPOINT=2
    out=$(_delegation_fragment secretary)
    [[ $out == *'provider: "deepseek"'* && $out == *'model: "deepseek-chat"'* && $out == *'base_url: ""'* && $out == *'api_key: ""'* ]]
    BOT_SECRETARY_DELEGATION_ENDPOINT=""
    out=$(_delegation_fragment secretary)
    [[ $out == *'model: ""'* && $out == *'provider: ""'* ]]
}

@test "a delegation endpoint must exist, carry a model, and never a key that would land in config.yaml" {
    BOTS="secretary" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    secret_nonempty() { [[ $1 == DEEPSEEK_API_KEY || $1 == KIMI_API_KEY ]]; }
    LLM_ENDPOINT_COUNT=3
    LLM_ENDPOINT_1_PROVIDER=custom LLM_ENDPOINT_1_BASE_URL=http://127.0.0.1:8787/v1 LLM_ENDPOINT_1_MODEL=fast LLM_ENDPOINT_1_TOKEN_VAR=""
    LLM_ENDPOINT_2_PROVIDER=deepseek LLM_ENDPOINT_2_MODEL=deepseek-chat LLM_ENDPOINT_2_TOKEN_VAR=DEEPSEEK_API_KEY
    LLM_ENDPOINT_3_PROVIDER=custom LLM_ENDPOINT_3_BASE_URL=https://api.example.com/v1 LLM_ENDPOINT_3_MODEL=other LLM_ENDPOINT_3_TOKEN_VAR=KIMI_API_KEY
    BOT_SECRETARY_LLM_PROVIDER=custom BOT_SECRETARY_LLM_BASE_URL=https://api.example.com/v1 BOT_SECRETARY_LLM_MODEL=kimi-k3 BOT_SECRETARY_LLM_TOKEN_VAR=KIMI_API_KEY
    BOT_SECRETARY_DELEGATION_ENDPOINT=1; _invalid=(); _check_delegation_endpoint secretary; [ "${#_invalid[@]}" -eq 0 ]
    BOT_SECRETARY_DELEGATION_ENDPOINT=2; _invalid=(); _check_delegation_endpoint secretary; [ "${#_invalid[@]}" -eq 0 ]
    BOT_SECRETARY_DELEGATION_ENDPOINT=3; _invalid=(); _check_delegation_endpoint secretary; [ "${#_invalid[@]}" -eq 1 ]
    BOT_SECRETARY_DELEGATION_ENDPOINT=4; _invalid=(); _check_delegation_endpoint secretary; [ "${#_invalid[@]}" -eq 1 ]
    BOT_SECRETARY_DELEGATION_ENDPOINT=x; _invalid=(); _check_delegation_endpoint secretary; [ "${#_invalid[@]}" -eq 1 ]
    BOT_SECRETARY_LLM_MODEL=""
    BOT_SECRETARY_DELEGATION_ENDPOINT=1; _invalid=(); _check_delegation_endpoint secretary; [ "${#_invalid[@]}" -eq 1 ]
}

@test "the model block always sets base_url: the endpoint for custom, empty for a hosted provider" {
    LLM_CONTEXT_WINDOW=512000 LLM_REASONING_FIELD=reasoning_content LLM_MAX_OUTPUT=0
    out=$(_model_fragment deepseek deepseek "" deepseek-chat)
    [[ $out == *'provider: "deepseek"'* && $out == *'base_url: ""'* && $out == *'context_length: 512000'* && $out == *'reasoning_field: "reasoning_content"'* ]]
    out=$(_model_fragment custom bridge http://127.0.0.1:8787/v1 fast)
    [[ $out == *'provider: "custom:bridge"'* && $out == *'base_url: "http://127.0.0.1:8787/v1"'* ]]
    # valid yaml with the empty string kept as a string
    python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin.read()); assert d["model"]["base_url"]==""' <<<"$(_model_fragment deepseek deepseek "" m)"
}

@test "tool_search is off by default, per bot overridable, and only auto/on/off pass" {
    unset AGENT_TOOL_SEARCH; config_defaults
    [ "$(bot_field secretary TOOL_SEARCH)" = off ]
    BOT_SECRETARY_TOOL_SEARCH=auto
    [ "$(bot_field secretary TOOL_SEARCH)" = auto ]; [ "$(bot_field news TOOL_SEARCH)" = off ]
    _invalid=(); _check_tool_search X sometimes; [ "${#_invalid[@]}" -eq 1 ]
    _invalid=(); _check_tool_search X on; [ "${#_invalid[@]}" -eq 0 ]
    unset BOT_SECRETARY_TOOL_SEARCH
}

@test "a bot's toolset may be a list, rendered as the platform's toolset list" {
    [ "$(_toolset_yaml teams hermes-telegram)" = $'platform_toolsets:\n  teams:\n    - hermes-telegram' ]
    [ "$(_toolset_yaml teams "web memory cronjob")" = $'platform_toolsets:\n  teams:\n    - web\n    - memory\n    - cronjob' ]
    [ "$(_toolset_yaml cron "memory todo")" = $'platform_toolsets:\n  cron:\n    - memory\n    - todo' ]
    # an empty list stays a list: null would hand the platform the agent's full default
    [ "$(_toolset_yaml cron "")" = $'platform_toolsets:\n  cron: []' ]
    BOTS="github" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    BOT_GITHUB_TOOLSET="web memory"
    [ "$(bot_field github TOOLSET)" = "web memory" ]
    [ "$(bot_field secretary TOOLSET)" = hermes-telegram ]
    unset BOT_GITHUB_TOOLSET
}

@test "a role that must not touch the host does not get the full composite" {
    # news and search say so themselves: never write files, use the web tools.
    # The composite is the vendor's personal-messaging set — terminal, files,
    # browser — and a news desk handed a terminal researches with curl.
    [ "$(bot_field news TOOLSET)" = "web memory session_search clarify cronjob todo" ]
    [ "$(bot_field search TOOLSET)" = "web browser memory session_search clarify cronjob todo" ]
    [[ "$(bot_field news TOOLSET)" != *terminal* ]]
    [ "$(bot_field secretary TOOLSET)" = hermes-telegram ]

    BOT_NEWS_TOOLSET="hermes-telegram"                 # the operator may still say so
    [ "$(bot_field news TOOLSET)" = hermes-telegram ]
    unset BOT_NEWS_TOOLSET

    CHANNEL_TEAMS_TOOLSET="web todo"                   # one set for every bot wins too
    [ "$(bot_field news TOOLSET)" = "web todo" ]
    [ "$(bot_field secretary TOOLSET)" = "web todo" ]
    CHANNEL_TEAMS_TOOLSET=$CHANNEL_TEAMS_TOOLSET_DEFAULT
}

@test "toolset names are checked against the registry; MCP servers and no_mcp pass" {
    tmp=$(mktemp -d); printf '    "web": {\n    "memory": {\n    "hermes-telegram": {\n' >"${tmp}/toolsets.py"
    hermes_install_dir() { printf '%s' "$tmp"; }
    die() { printf 'die: %s\n' "$*"; exit 1; }
    ASSISTANT_GITHUB_ENABLED=true ASSISTANT_M365_ENABLED=false
    ( _toolset_check "web memory github no_mcp" )
    bats_run _toolset_check "web terminal"        # bats_run: the libs define their own `run`
    [ "$status" -ne 0 ] && [[ "$output" == *"'terminal'"* ]]
    bats_run _toolset_check "m365"
    [ "$status" -ne 0 ]
    rm -rf "$tmp"
}

# ADR 0028: on the bridge the model searches the web itself. A bot whose every
# endpoint is the bridge gets the agent's own web_search subtracted — through
# its one-tool toolset `search` in agent.disabled_toolsets — while web_extract,
# the page reader, stays. Everything else the operator disabled stays disabled.
@test "a bot on the bridge with the CLI's search loses the agent's web_search, keeps web_extract" {
    tmp=$(mktemp -d)
    HERMES_CONFIG_HOME=$tmp DRY_RUN=false
    printf 'agent:\n  disabled_toolsets:\n  - image_gen\n' >"${tmp}/config.yaml"
    AGY_SHIM_ENABLED=true AGY_SHIM_HOST=127.0.0.1 AGY_SHIM_PORT=8787
    LLM_ENDPOINT_COUNT=1 LLM_ENDPOINT_1_BASE_URL="http://127.0.0.1:8787/v1"
    AGY_SHIM_BUILTIN_TOOLS=search_web
    disabled() { python3 -c 'import sys,yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["agent"]["disabled_toolsets"]))' "${tmp}/config.yaml"; }

    _native_search_configure
    [ "$(disabled)" = "image_gen search" ]
    _native_search_configure                                # idempotent
    [ "$(disabled)" = "image_gen search" ]

    AGY_SHIM_BUILTIN_TOOLS=""                               # the CLI's search switched off: the agent's is back
    _native_search_configure
    [ "$(disabled)" = "image_gen" ]
    AGY_SHIM_BUILTIN_TOOLS=search_web

    LLM_ENDPOINT_1_BASE_URL="http://127.0.0.1:8790/v1"      # an API model has no search of its own
    ! llm_chain_on_bridge
    LLM_ENDPOINT_1_BASE_URL="http://127.0.0.1:8787/v1"
    LLM_ENDPOINT_COUNT=2 LLM_ENDPOINT_2_BASE_URL="https://api.example.com/v1"
    ! llm_chain_on_bridge                                   # nor does a fallback on an API
    LLM_ENDPOINT_COUNT=1
    llm_chain_on_bridge
    AGY_SHIM_ENABLED=false
    ! llm_chain_on_bridge
    rm -rf "$tmp"
}

# The same list for every way into a bot: chat, mail, scheduled runs. Unset,
# the agent hands mail and cron its full default — terminal and files.
@test "chat, mail and scheduled runs get the bot's own toolset, not the agent's full default" {
    grep -qE '^    _platform_toolset_configure cron$' "$REPO_ROOT/libs/80-channels.sh"
    grep -qE '^    _platform_toolset_configure email$' "$REPO_ROOT/libs/80-channels.sh"
    grep -qE '^_channel_teams_toolset\(\) \{ _platform_toolset_configure teams; \}' "$REPO_ROOT/libs/80-channels.sh"
    DRY_RUN=true
    yaml_merge() { cat; }
    BOT_TOOLSET="web memory"
    [ "$(_platform_toolset_configure cron)" = $'platform_toolsets:\n  cron:\n    - web\n    - memory' ]
    [ "$(_platform_toolset_configure email)" = $'platform_toolsets:\n  email:\n    - web\n    - memory' ]
    BOT_TOOLSET=""                                          # a single agent: the global setting
    [ "$(_platform_toolset_configure cron)" = $'platform_toolsets:\n  cron:\n    - hermes-telegram' ]
}

@test "one bot's toolset never leaks into the next one's" {
    # bot_role_toolset reads CHANNEL_TEAMS_TOOLSET as the operator's set for
    # every bot; the pass used to write each bot's list into it, so news (after
    # search) ran on search's list.
    ! grep -qE '^\s+CHANNEL_TEAMS_TOOLSET=\$\(bot_field' "$REPO_ROOT/libs/80-channels.sh"
    grep -qE '^\s+BOT_TOOLSET=\$\(bot_field "\$key" TOOLSET\)' "$REPO_ROOT/libs/80-channels.sh"
    local key; declare -A got
    for key in search news; do
        BOT_TOOLSET=$(bot_field "$key" TOOLSET); got[$key]=$BOT_TOOLSET
    done
    [ "${got[search]}" = "web browser memory session_search clarify cronjob todo" ]
    [ "${got[news]}" = "web memory session_search clarify cronjob todo" ]
    [ "$CHANNEL_TEAMS_TOOLSET" = "$CHANNEL_TEAMS_TOOLSET_DEFAULT" ]
}

@test "the mail poll interval reaches the adapter through the environment, a minute by default" {
    # The adapter reads EMAIL_POLL_INTERVAL from the environment only; the YAML
    # key alone left every bot polling every 15 s.
    grep -q '_env_upsert EMAIL_POLL_INTERVAL "${CHANNEL_EMAIL_POLL_INTERVAL:-60}"' "$REPO_ROOT/libs/80-channels.sh"
    grep -q '^CHANNEL_EMAIL_POLL_INTERVAL=60$' "$REPO_ROOT/config/channels.conf.example"
    grep -q 'CHANNEL_EMAIL_POLL_INTERVAL must be a number of seconds' "$REPO_ROOT/libs/20-config.sh"
}

@test "every persona says where scratch goes and that it is removed" {
    BOTS="secretary" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    bot_context secretary
    out=$(profile_soul_text "$REPO_ROOT/bot/roles/secretary.md")
    bot_context_end
    [[ $out == *'never into the account'"'"'s home directory and never into /tmp'* ]]
    [[ $out == *'working directory'* ]]
}

@test "every role carries a one-line summary and /help renders it with the bot's name" {
    BOTS="secretary" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    for r in "$REPO_ROOT"/bot/roles/*.md; do [ -n "$(role_summary "$r")" ]; done
    bot_context secretary
    out=$(BOT_DISPLAY_NAME=$BOT_DISPLAY_NAME profile_help_text "$REPO_ROOT/bot/roles/secretary.md")
    bot_context_end
    [[ $out == "**X Secretary**"* && $out == *'/help all'* && $out == *secretary* && $out != *'${'* ]]
    [[ $out == *'**What I do**'* && $out == *'**Examples**'* && $out == *'**Commands**'* ]]
    [[ $out != *'•'* ]]                                  # Teams joins single-newline lines: only "- " lists survive
    for r in "$REPO_ROOT"/bot/help/*.md; do ! grep -qE '^• ' "$r"; done
}

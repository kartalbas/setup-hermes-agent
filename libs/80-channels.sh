# shellcheck shell=bash
#
# Inference providers, messaging channels, and the policy around unattended
# turns.
#
# The agent owns its own configuration files: it rewrites config.yaml during
# setup and migrations, and it manages .env. So every write here is a key-level
# upsert rather than a rendered template. Overwriting either file would destroy
# whatever the agent wrote and would make every re-run report a change.

channels_apply() {
    log_step "Providers and channels"

    if (( $(bot_count) == 0 )); then
        _channels_apply_one "${SERVICE_NAME}"
        return 0
    fi

    # One pass per bot, inside its profile. The channel variables are set from
    # the bot's declaration for the duration of the pass; only Teams and mail
    # exist here, and mail can be on one bot.
    local key
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"
        log_info "bot            ${BOT_KEY} (${BOT_DISPLAY_NAME})"
        CHANNEL_TELEGRAM_ENABLED=false
        CHANNEL_WHATSAPP_ENABLED=false
        CHANNEL_TEAMS_ENABLED=$(bot_has_channel "$key" teams && printf true || printf false)
        CHANNEL_EMAIL_ENABLED=$(bot_has_channel "$key" email && printf true || printf false)
        CHANNEL_EMAIL_FOLDER=$(bot_field "$key" MAIL_FOLDER)
        CHANNEL_TEAMS_CLIENT_ID_VAR=$BOT_TEAMS_CLIENT_ID_VAR
        CHANNEL_TEAMS_CLIENT_SECRET_VAR=$BOT_TEAMS_CLIENT_SECRET_VAR
        CHANNEL_TEAMS_PORT=$BOT_PORT
        CHANNEL_TEAMS_TOOLSET=$(bot_field "$key" TOOLSET)
        # Read from the global endpoints, so before bot_llm_apply replaces them.
        _DELEGATION_FRAGMENT=$(_delegation_fragment "$key")
        _delegation_key_env "$key"
        bot_llm_apply "$key"
        _channels_apply_one "$BOT_SERVICE"
        bot_llm_restore
        _DELEGATION_FRAGMENT=""
        bot_context_end
    done < <(bots)
}

# ---------------------------------------------------------------------------
# Sub-agents on another endpoint
#
# The agent's delegate_task tool runs sub-agents on the `delegation:` block of
# the profile: empty values mean "inherit the parent's model". A bot that runs
# on an API model can point its sub-agents at a global LLM_ENDPOINT_n — the
# bridge, say — so the work it hands off (reading the operator's own mail) runs
# on the subscription and its content never reaches the API. Two shapes only:
# a keyless custom endpoint (base_url + the marker) or a hosted provider (by
# name, key in .env). Validation refuses the third, a custom endpoint with a
# key, because the block has no key_env and the key would land in config.yaml.
# ---------------------------------------------------------------------------
_delegation_fragment() {          # _delegation_fragment KEY -> yaml (always a block; empty values = inherit)
    local key=$1 n provider base model
    n=$(bot_field "$key" DELEGATION_ENDPOINT)
    if [[ -z $n ]]; then
        printf 'delegation:\n  model: ""\n  provider: ""\n  base_url: ""\n  api_key: ""\n'
        return 0
    fi
    provider=$(endpoint_field "$n" PROVIDER); provider=${provider:-custom}
    base=$(endpoint_field "$n" BASE_URL)
    model=$(endpoint_field "$n" MODEL)
    printf 'delegation:\n  model: "%s"\n' "$model"
    if [[ $provider == custom ]]; then
        printf '  provider: ""\n  base_url: "%s"\n  api_mode: "chat_completions"\n  api_key: "%s"\n' "$base" "bridge-does-not-check-keys"
    else
        printf '  provider: "%s"\n  base_url: ""\n  api_key: ""\n' "$provider"
    fi
}

# A hosted delegation provider reads its key from the variable the agent
# expects; the bot's pass writes only its own model's key, so this one is
# added here (the profile's .env, bot_context being active).
_delegation_key_env() {           # _delegation_key_env KEY
    local key=$1 n provider tv
    n=$(bot_field "$key" DELEGATION_ENDPOINT)
    [[ -n $n ]] || return 0
    provider=$(endpoint_field "$n" PROVIDER); provider=${provider:-custom}
    [[ $provider != custom ]] || return 0
    tv=$(endpoint_field "$n" TOKEN_VAR)
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] delegation key $(_provider_key_var "$provider") from ${tv}"; return 0; }
    _env_upsert "$(_provider_key_var "$provider")" "$(secret_get "$tv")"
}

# Providers, policy and channels for the profile the config helpers point at;
# UNIT is what gets restarted when this pass changed something.
_channels_apply_one() {
    local unit=$1
    _CHANNELS_COUNT_BEFORE=$CHANGE_COUNT

    _providers_configure
    _policy_configure

    # One channel that cannot be configured must not take the others with it.
    # A mailbox refused by its provider is a provider-side setting, and there is
    # no reason for it to leave Teams unconfigured, the dashboard unpublished
    # and no backup timer — which is what happened: the run died here and three
    # later modules never ran at all.
    #
    # Each channel is still all-or-nothing in itself: a failing one writes no
    # configuration and stays disabled. The run then fails at the end, naming
    # every channel that did not come up, the way the tool catalogue does.
    local -a failed=()
    _channel_telegram || failed+=(telegram)
    _channel_email    || failed+=(email)
    _channel_whatsapp || failed+=(whatsapp)
    _channel_teams    || failed+=(teams)

    _channels_restart_if_changed "$unit"

    if (( ${#failed[@]} > 0 )); then
        local IFS=$' \t\n'
        defer_failure "channels not configured${BOT_KEY:+ for ${BOT_KEY}}: ${failed[*]}"
    fi
}

# When the transcript starts over. The agent's at_hour is local time of the
# host (TIMEZONE). Nothing outside the transcript is touched by a reset.
_session_reset_configure() {
    local spec=${BOT_KEY:+$(bot_field "$BOT_KEY" SESSION_RESET)}
    spec=${spec:-$AGENT_SESSION_RESET}
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] session reset: ${spec}"
        return 0
    fi
    yaml_merge <<<"$(session_reset_yaml "$spec")"
}

# MCP tools inline or behind the agent's meta-tools — see AGENT_TOOL_SEARCH.
_tool_search_configure() {
    local mode=${BOT_KEY:+$(bot_field "$BOT_KEY" TOOL_SEARCH)}
    mode=${mode:-$AGENT_TOOL_SEARCH}
    _config_set tools.tool_search.enabled "$mode"
}

# Every adapter splits its allowlist on COMMAS — verified in the telegram,
# email and teams adapters, all `split(",")`. Written space-separated, two
# entries become one token that matches nobody. The gate fails closed, so it is
# safe and completely silent: the second person simply never gets a reply, and
# nothing anywhere says why. Accept either spelling and hand the adapters what
# they actually parse.
_allowlist_csv() {
    local IFS=$' \t\n'
    local -a items=()
    # shellcheck disable=SC2206  # deliberate splitting on whitespace and commas
    items=( ${1//,/ } )
    local joined="" item
    for item in ${items+"${items[@]}"}; do joined+="${joined:+,}${item}"; done
    printf '%s' "$joined"
}

# ---------------------------------------------------------------------------
# .env upsert
#
# The agent reads its secrets from .env. Values are written by replacing the
# line for a key, or appending it, and never by rewriting the file wholesale.
# ---------------------------------------------------------------------------
_env_file() {
    printf '%s/.env' "${HERMES_CONFIG_HOME:-$HERMES_HOME}"
}

_env_upsert() {
    local key=$1 value=$2 file
    file=$(_env_file)

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] set ${key} in ${file}"
        return 0
    fi

    [[ -f $file ]] || { : >"$file"; chmod 0600 "$file"; }

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        local current
        current=$(sed -n "s/^${key}=//p" "$file" | head -n1)
        # Strip one layer of quotes for comparison.
        current=${current%\"}; current=${current#\"}
        if [[ $current == "$value" ]]; then
            log_skip "${key} already set"
            return 0
        fi
    fi

    local tmp
    tmp=$(mktemp "${file}.XXXXXX"); chmod 0600 "$tmp"
    grep -v "^${key}=" "$file" 2>/dev/null >"$tmp" || true
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv -f "$tmp" "$file"
    [[ -n ${SERVICE_USER:-} ]] && chown "${SERVICE_USER}:${SERVICE_GROUP}" "$file"
    mark_changed
    log_ok "set ${key}"
}

_config_set() {
    local key=$1 value=$2
    # Handled here rather than inside hermes_cli: the call below discards output,
    # which would otherwise hide every configuration change from --dry-run.
    if [[ ${DRY_RUN:-false} == true ]]; then
        log_info "[dry-run] config set ${key} = ${value}"
        return 0
    fi
    # Read first: the agent's CLI takes seconds per call, and most keys are
    # already right on every run after the first.
    local current; current=$(yaml_get "$key")
    if [[ $current == "$value" || $current == "${value,,}" ]]; then
        log_skip "${key} already ${value}"
        return 0
    fi
    if hermes_cli config set "$key" "$value" >/dev/null 2>&1; then
        log_ok "set ${key} = ${value}"
        mark_changed
    else
        log_warn "could not set ${key}; set it by hand if the agent needs it"
    fi
}

# ---------------------------------------------------------------------------
# Inference providers
#
# Two shapes, chosen by LLM_ENDPOINT_n_PROVIDER:
#
#   custom            a self-hosted OpenAI-compatible endpoint. Declared as a
#                     named entry under providers:, referenced as custom:<name>,
#                     with its key held in .env via key_env.
#   anything else     a hosted provider the agent already knows (anthropic,
#                     openai, google, openrouter, kimi-coding, zai, ...). No
#                     base_url; the key goes to the variable that provider
#                     expects.
#
# Endpoint 1 is the model in use. Endpoints 2..n become the fallback chain,
# consulted within the same turn when the one before them fails — which is what
# makes a second endpoint worth having: the agent keeps answering while a host
# is down rather than surfacing an error to whoever is waiting.
#
# Keys never reach config.yaml. That file is ordinary enough to read, copy into
# a bug report, or back up somewhere less careful.
# ---------------------------------------------------------------------------

# The environment variable each hosted provider reads its key from.
_provider_key_var() {
    case $1 in
        anthropic)    printf 'ANTHROPIC_API_KEY' ;;
        openai)       printf 'OPENAI_API_KEY' ;;
        google)       printf 'GOOGLE_API_KEY' ;;
        openrouter)   printf 'OPENROUTER_API_KEY' ;;
        deepseek)     printf 'DEEPSEEK_API_KEY' ;;
        groq)         printf 'GROQ_API_KEY' ;;
        qwen)         printf 'QWEN_API_KEY' ;;
        xai)          printf 'XAI_API_KEY' ;;
        kimi-coding|kimi-coding-cn) printf 'KIMI_API_KEY' ;;
        zai)          printf 'GLM_API_KEY' ;;
        *)            return 1 ;;
    esac
}

# The model block. `base_url` is always written: the agent's own default
# config.yaml carries the vendor's aggregator URL there, and for a hosted
# provider an explicit model.base_url wins over the provider's registry
# address — a bot switched from a custom endpoint to a hosted provider then
# sent its requests, keyless, to the aggregator ("HTTP 401: Missing
# Authentication header", 2026-09-07). Empty means "the provider's own address".
_model_fragment() {               # _model_fragment PROVIDER NAME BASE MODEL -> yaml
    local provider=$1 name=$2 base=$3 model=$4 frag
    frag="model:"$'\n'
    frag+="  default: \"${model}\""$'\n'
    if [[ $provider == custom ]]; then
        frag+="  provider: \"custom:${name}\""$'\n'
        frag+="  base_url: \"${base}\""$'\n'
    else
        frag+="  provider: \"${provider}\""$'\n'
        frag+="  base_url: \"\""$'\n'
    fi
    [[ ${LLM_CONTEXT_WINDOW:-0} != 0 ]] && frag+="  context_length: ${LLM_CONTEXT_WINDOW}"$'\n'
    [[ ${LLM_MAX_OUTPUT:-0} != 0 ]]     && frag+="  max_tokens: ${LLM_MAX_OUTPUT}"$'\n'
    [[ -n ${LLM_REASONING_FIELD:-} ]]   && frag+="  reasoning_field: \"${LLM_REASONING_FIELD}\""$'\n'
    printf '%s' "$frag"
}

_providers_configure() {
    local frag_providers="" frag_model="" frag_fallback=""
    local i provider name base model token_var token key_var

    for (( i = 1; i <= LLM_ENDPOINT_COUNT; i++ )); do
        provider=$(endpoint_field "$i" PROVIDER); provider=${provider:-custom}
        name=$(endpoint_field "$i" NAME);         name=${name:-endpoint${i}}
        base=$(endpoint_field "$i" BASE_URL)
        model=$(endpoint_field "$i" MODEL)
        token_var=$(endpoint_field "$i" TOKEN_VAR)

        [[ -n $model ]] || continue

        # Where this endpoint's key lands in .env.
        if [[ $provider == custom ]]; then
            key_var="HERMES_LLM_KEY_${i}"
        else
            key_var=$(_provider_key_var "$provider") ||
                die "unknown provider '${provider}' for endpoint ${i}"
        fi

        if [[ -n $token_var ]] && secret_has "$token_var"; then
            token=$(secret_get "$token_var")
            _env_upsert "$key_var" "$token"
        elif [[ $provider != custom ]]; then
            die "endpoint ${i} (${provider}) has no key in SECRETS_FILE"
        else
            # A keyless local endpoint (the bridge). The agent's auxiliary
            # client resolves key_env on its own and warns on every turn when
            # the variable is absent OR equals its own placeholder
            # "no-key-required"; any other value passes. The bridge does not
            # read the Authorization header at all.
            _env_upsert "$key_var" "bridge-does-not-check-keys"
        fi

        if [[ $provider == custom ]]; then
            frag_providers+="  ${name}:"$'\n'
            frag_providers+="    api: \"${base}\""$'\n'
            frag_providers+="    key_env: ${key_var}"$'\n'
            frag_providers+="    transport: chat_completions"$'\n'
        fi

        if (( i == 1 )); then
            frag_model=$(_model_fragment "$provider" "$name" "$base" "$model")$'\n'
            log_ok "model: ${model} via ${provider}${base:+ at ${base}}"
        elif [[ $LLM_STRATEGY == failover ]]; then
            frag_fallback+="  - provider: \"${provider}\""$'\n'
            [[ -n $base ]] && frag_fallback+="    base_url: \"${base}\""$'\n'
            frag_fallback+="    model: \"${model}\""$'\n'
            log_ok "fallback ${i}: ${model} via ${provider}${base:+ at ${base}}"
        else
            log_skip "endpoint ${i} configured but unused (LLM_STRATEGY=${LLM_STRATEGY})"
        fi
    done

    # Assembled into one string and passed by here-string rather than piped:
    # a pipeline would run yaml_merge in a subshell and lose the change flag,
    # so a rewritten config.yaml would never trigger a restart.
    local fragment=""
    [[ -n $frag_providers ]] && fragment+="providers:"$'\n'"${frag_providers}"
    fragment+="$frag_model"
    [[ -n $frag_fallback ]] && fragment+="fallback_providers:"$'\n'"${frag_fallback}"
    [[ -n ${_DELEGATION_FRAGMENT:-} ]] && fragment+="$_DELEGATION_FRAGMENT"
    yaml_merge <<<"$fragment"

    return 0
}

# ---------------------------------------------------------------------------
# Policy for turns nobody is watching
# ---------------------------------------------------------------------------
_policy_configure() {
    _config_set approvals.unattended_mode "$CHANNELS_UNATTENDED_MODE"
    _config_set approvals.cron_mode       "$CHANNELS_CRON_MODE"
    _session_reset_configure
    _tool_search_configure

    if [[ -n ${CHANNELS_APPROVALS_DENY:-} ]]; then
        # Kept as a denylist rather than a habit: the agent can otherwise be
        # talked into upgrading itself off the pinned revision, or into running
        # a downloaded script, by anyone whose message it reads.
        # Local IFS: the script sets IFS to newline/tab, so this space-separated
        # list would otherwise be treated as a single pattern and the denylist
        # would silently protect nothing.
        local pattern IFS=$' \t\n'
        for pattern in $CHANNELS_APPROVALS_DENY; do
            _config_set "approvals.deny.${pattern}" true
        done
        log_ok "approval denylist applied"
    fi
    log_info "unattended     ${CHANNELS_UNATTENDED_MODE}; cron ${CHANNELS_CRON_MODE}"
}

# ---------------------------------------------------------------------------
# Channels
#
# An allowlist is written in the same operation that enables the channel. Doing
# it afterwards leaves a window, however short, in which anyone who can find the
# address can instruct the agent.
# ---------------------------------------------------------------------------

_channel_guard_allowlist() {
    local name=$1 allow_all=$2 list_var=$3
    if is_true "$allow_all"; then
        log_warn "${name}: accepting every sender (ALLOW_ALL=true)"
        confirm "Really let anyone instruct the agent over ${name}?" ||
            die "${name}: refused"
        return 1
    fi
    secret_nonempty "$list_var" ||
        die "${name} is enabled but '${list_var}' is missing or empty in SECRETS_FILE; an allowlist is required"
    return 0
}

# unauthorized_dm_behavior defaults to "pair", not "ignore": a stranger who
# finds the bot is handed to the pairing handshake rather than dropped. A bot
# username is discoverable and cannot be hidden, so the allowlist is the whole
# boundary — and a channel that lets an unknown sender open a conversation is
# not a boundary. Set it explicitly wherever a channel is enabled.
_channel_deny_pairing() {
    _config_set "platforms.$1.unauthorized_dm_behavior" ignore
}

# Skipping a disabled channel is not disabling it. The agent keeps whatever it
# was last told, so a toggle flipped to false left the platform running and the
# configuration claiming otherwise — the one state a config-driven installer
# must never produce.
_channel_disable() {
    local name=$1
    _config_set "platforms.${name}.enabled" false
    # A channel that is off should not leave its credentials behind: a token
    # for a bot that no longer exists is still a token in a file the agent
    # reads, and a re-enabled channel should start from configuration, not from
    # whatever the previous life left in .env.
    _env_drop_prefix "${name^^}_"
    log_skip "${name} disabled"
}

# Remove every .env key with the given prefix, reporting each.
_env_drop_prefix() {
    local prefix=$1 file; file=$(_env_file)
    [[ -f $file ]] || return 0
    local -a keys=()
    mapfile -t keys < <(grep -oE "^${prefix}[A-Z0-9_]*=" "$file" 2>/dev/null | tr -d '=' || true)
    (( ${#keys[@]} == 0 )) && return 0
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] remove from .env: ${keys[*]}"
        return 0
    fi
    local k
    for k in "${keys[@]}"; do
        run sed -i "/^${k}=/d" "$file"
        log_ok "removed ${k} from .env"
    done
    mark_changed
}

_channel_telegram() {
    is_true "${CHANNEL_TELEGRAM_ENABLED:-false}" || { _channel_disable telegram; return 0; }
    log_info "channel        telegram"

    if _channel_guard_allowlist telegram "${CHANNEL_TELEGRAM_ALLOW_ALL:-false}" "${CHANNEL_TELEGRAM_ALLOWLIST_VAR}"; then
        _env_upsert TELEGRAM_ALLOWED_USERS "$(_allowlist_csv "$(secret_get "$CHANNEL_TELEGRAM_ALLOWLIST_VAR")")"
    fi
    _env_upsert TELEGRAM_BOT_TOKEN "$(secret_require "$CHANNEL_TELEGRAM_TOKEN_VAR" telegram)"
    _config_set platforms.telegram.enabled true
    _channel_deny_pairing telegram
}

# Which of the two mailboxes is in use. Everything downstream reads these, so
# the choice is made once and cannot drift between address, host and password.
_email_resolve() {
    local which=${CHANNEL_EMAIL_ACCOUNT:-}
    case $which in
        private|work) ;;
        *) die "CHANNEL_EMAIL_ACCOUNT must be 'private' or 'work', got '${which}'" ;;
    esac
    local u=${which^^}
    local a="CHANNEL_EMAIL_${u}_ADDRESS" i="CHANNEL_EMAIL_${u}_IMAP_HOST"
    local m="CHANNEL_EMAIL_${u}_SMTP_HOST" p="CHANNEL_EMAIL_${u}_PASSWORD_VAR"
    EMAIL_ACCOUNT_LABEL=$which
    EMAIL_ADDRESS_RESOLVED=${!a:-}
    EMAIL_IMAP_RESOLVED=${!i:-}
    EMAIL_SMTP_RESOLVED=${!m:-}
    EMAIL_PASSWORD_VAR_RESOLVED=${!p:-}

    # With the relay in front, the adapter talks to loopback and the relay does
    # the OAuth. The mailbox address stays the real one: it is what the relay
    # authenticates as, and what the agent sends from.
    if [[ $which == work ]] && is_true "${MAILPROXY_ENABLED:-false}"; then
        EMAIL_IMAP_RESOLVED=${MAILPROXY_LISTEN}
        EMAIL_SMTP_RESOLVED=${MAILPROXY_LISTEN}
        EMAIL_IMAP_PORT_RESOLVED=${MAILPROXY_IMAP_PORT}
        EMAIL_SMTP_PORT_RESOLVED=${MAILPROXY_SMTP_PORT}
        # TLS on the loopback hop too, because the pinned agent gives us no
        # choice: it connects with imaplib.IMAP4_SSL and nothing else. The relay
        # therefore holds a self-signed certificate for 127.0.0.1 that the
        # system store trusts — see src/55-mailproxy.sh.
        EMAIL_IMAP_SECURITY_RESOLVED=tls
        EMAIL_SMTP_SECURITY_RESOLVED=starttls
        # The mailbox password is reused for the loopback login. The relay does
        # not check it against anything upstream — it holds the OAuth token —
        # so inventing a second secret would only be one more thing to lose.
    else
        EMAIL_IMAP_PORT_RESOLVED=${CHANNEL_EMAIL_IMAP_PORT}
        EMAIL_SMTP_PORT_RESOLVED=${CHANNEL_EMAIL_SMTP_PORT}
        EMAIL_IMAP_SECURITY_RESOLVED=${CHANNEL_EMAIL_IMAP_SECURITY}
        EMAIL_SMTP_SECURITY_RESOLVED=${CHANNEL_EMAIL_SMTP_SECURITY}
    fi

    [[ -n $EMAIL_ADDRESS_RESOLVED ]] || die "${a} is empty"
    [[ -n $EMAIL_IMAP_RESOLVED ]]    || die "${i} is empty"
    [[ -n $EMAIL_SMTP_RESOLVED ]]    || die "${m} is empty"
    [[ -n $EMAIL_PASSWORD_VAR_RESOLVED ]] || die "${p} is empty"
}

_channel_email() {
    is_true "${CHANNEL_EMAIL_ENABLED:-false}" || { _channel_disable email; return 0; }

    _email_resolve
    log_info "channel        email (${EMAIL_ACCOUNT_LABEL}: ${EMAIL_ADDRESS_RESOLVED})"

    local password
    password=$(secret_require "$EMAIL_PASSWORD_VAR_RESOLVED" "the ${EMAIL_ACCOUNT_LABEL} mailbox")

    # Probe before writing anything. The adapter authenticates with a password
    # only, and several providers have disabled that for IMAP; finding out here
    # is far cheaper than finding out from an agent that silently never sees
    # mail.
    if is_true "${CHANNEL_EMAIL_PROBE_LOGIN:-true}"; then
        _email_probe "$password" || return 1
    fi

    if _channel_guard_allowlist email "${CHANNEL_EMAIL_ALLOW_ALL:-false}" "${CHANNEL_EMAIL_ALLOWLIST_VAR}"; then
        _env_upsert EMAIL_ALLOWED_USERS "$(_allowlist_csv "$(secret_get "$CHANNEL_EMAIL_ALLOWLIST_VAR")")"
    fi

    _env_upsert EMAIL_ADDRESS   "$EMAIL_ADDRESS_RESOLVED"
    # The folder this bot polls (carried adapter patch, see 60-hermes.sh).
    _env_upsert EMAIL_IMAP_FOLDER "${CHANNEL_EMAIL_FOLDER:-INBOX}"
    _env_upsert EMAIL_PASSWORD  "$password"
    _env_upsert EMAIL_IMAP_HOST "$EMAIL_IMAP_RESOLVED"
    _env_upsert EMAIL_IMAP_PORT "$EMAIL_IMAP_PORT_RESOLVED"
    _env_upsert EMAIL_SMTP_HOST "$EMAIL_SMTP_RESOLVED"
    _env_upsert EMAIL_SMTP_PORT "$EMAIL_SMTP_PORT_RESOLVED"
    [[ -n ${CHANNEL_EMAIL_HOME_ADDRESS:-} ]] && _env_upsert EMAIL_HOME_ADDRESS "$CHANNEL_EMAIL_HOME_ADDRESS"

    _config_set platforms.email.enabled          true
    _channel_deny_pairing email
    # Also in .env, because the adapter reads the environment FIRST:
    #   _normalize_security(setting("EMAIL_IMAP_SECURITY", "imap_security"))
    # Setting only the YAML left it on its default of tls, so the agent spoke
    # TLS to the relay's plaintext loopback socket and logged
    # "[SSL: WRONG_VERSION_NUMBER]" once a minute — while our own probe, which
    # used the resolved value, reported the login as accepted. A check that does
    # not do what the thing it checks does is not a check.
    _env_upsert EMAIL_IMAP_SECURITY "$EMAIL_IMAP_SECURITY_RESOLVED"
    _env_upsert EMAIL_SMTP_SECURITY "$EMAIL_SMTP_SECURITY_RESOLVED"

    _config_set platforms.email.imap_security    "$EMAIL_IMAP_SECURITY_RESOLVED"
    _config_set platforms.email.smtp_security    "$EMAIL_SMTP_SECURITY_RESOLVED"
    _config_set platforms.email.imap_tls_verify  "$(is_true "$CHANNEL_EMAIL_TLS_VERIFY" && printf true || printf false)"
    _config_set platforms.email.smtp_tls_verify  "$(is_true "$CHANNEL_EMAIL_TLS_VERIFY" && printf true || printf false)"
    _config_set platforms.email.skip_attachments "$(is_true "${CHANNEL_EMAIL_SKIP_ATTACHMENTS:-true}" && printf true || printf false)"
    _config_set platforms.email.poll_interval    "${CHANNEL_EMAIL_POLL_INTERVAL:-15}"
    _config_set platforms.email.require_authenticated_sender \
        "$(is_true "${CHANNEL_EMAIL_REQUIRE_AUTHENTICATED_SENDER:-true}" && printf true || printf false)"
}

# A real login, not a port check. Reachability says nothing about whether the
# provider will accept password authentication for this mailbox.
_email_probe_once() {          # exit 0 ok, 2 rejected credentials, 3 unreachable/transient
    local password=$1
    # Credentials go through the environment, not argv.
    HERMES_PROBE_HOST=$EMAIL_IMAP_RESOLVED \
       HERMES_PROBE_PORT=$EMAIL_IMAP_PORT_RESOLVED \
       HERMES_PROBE_USER=$EMAIL_ADDRESS_RESOLVED \
       HERMES_PROBE_PASS=$password \
       HERMES_PROBE_SECURITY=$EMAIL_IMAP_SECURITY_RESOLVED \
       python3 - <<'PY'
import imaplib, os, ssl, sys
host = os.environ["HERMES_PROBE_HOST"]
port = int(os.environ["HERMES_PROBE_PORT"])
# Must match what the adapter will do. Through the relay the hop is plaintext
# over loopback, and probing with implicit TLS would fail on the handshake and
# be reported as a rejected password.
security = os.environ.get("HERMES_PROBE_SECURITY", "tls")
try:
    if security == "plain":
        m = imaplib.IMAP4(host, port, timeout=20)
    elif security == "starttls":
        m = imaplib.IMAP4(host, port, timeout=20)
        m.starttls(ssl_context=ssl.create_default_context())
    else:
        m = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(), timeout=20)
    m.login(os.environ["HERMES_PROBE_USER"], os.environ["HERMES_PROBE_PASS"])
    m.logout()
except imaplib.IMAP4.error as e:
    sys.stderr.write("IMAP rejected the login: %s\n" % e)
    sys.exit(2)
except Exception as e:
    sys.stderr.write("could not reach the IMAP server: %s\n" % e)
    sys.exit(3)
PY
}

_email_probe() {
    local password=$1
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] would probe the IMAP login"; return 0; }
    have_cmd python3 || die "python3 is needed to verify the mailbox login before configuring it"

    log_info "probing ${EMAIL_ACCOUNT_LABEL} IMAP login at ${EMAIL_IMAP_RESOLVED}:${EMAIL_IMAP_PORT_RESOLVED}"

    # The relay drops a session now and then (an EOF the adapter also sees and
    # survives); one such moment must not turn into "the provider refused the
    # login". Three attempts, then the diagnosis.
    local rc=0 attempt
    for attempt in 1 2 3; do
        # Not `if probe; then`: after an if-construct $? is the construct's
        # status (0), not the probe's — the exit code has to be taken directly.
        _email_probe_once "$password" && rc=0 || rc=$?
        if (( rc == 0 )); then
            log_ok "IMAP login accepted"
            return 0
        fi
        # A refusal through the relay is, more often than not, a cached access
        # token that predates a consent change — renew it once, then judge.
        if (( rc == 2 && attempt == 1 )) && _email_via_relay && mailproxy_force_refresh; then
            continue
        fi
        (( rc == 3 && attempt < 3 )) || break
        log_info "  transient failure (attempt ${attempt}/3); retrying in ${_EMAIL_PROBE_RETRY_DELAY:-5}s"
        sleep "${_EMAIL_PROBE_RETRY_DELAY:-5}"
    done

    # Through the relay the password is not what failed — the relay accepts any
    # loopback login and authenticates upstream with OAuth. A failure here means
    # it has no token yet, and saying "the server refused the password" would
    # send the reader to reset a password that is not the problem.
    if _email_via_relay; then
        # Two different failures reach this point and they need different
        # answers. Whether the relay holds a token decides which — saying "it
        # has no token yet" to someone who has already signed in sends them
        # round the same loop a second time.
        if grep -q '^refresh_token' "$(mailproxy_config_path)" 2>/dev/null; then
            log_error "The relay is authorised, but the provider refused the session."
            log_error "  A token is stored, so the app registration and the sign-in worked."
            log_error "  What is left is on the provider's side. The two usual causes:"
            log_error ""
            log_error "  1. IMAP is switched off for this mailbox. It is a per-mailbox"
            log_error "     setting and blocks OAuth sessions too, independently of the"
            log_error "     tenant-wide basic-authentication switch:"
            log_error "       admin centre -> Users -> ${EMAIL_ADDRESS_RESOLVED} -> Mail"
            log_error "         -> Manage email apps -> IMAP"
            log_error "     Allow up to an hour for it to take effect."
            log_error ""
            log_error "  2. The browser signed in as somebody else. The device flow uses"
            log_error "     whatever session the browser already had, so a token issued to"
            log_error "     another account produces exactly this message. Repeat the"
            log_error "     sign-in in a private window, explicitly as ${EMAIL_ADDRESS_RESOLVED}:"
            log_error "       rm $(mailproxy_config_path) && re-run"
        else
            log_error "The relay did not complete the login."
            log_error "  It is running, but it has no token for ${EMAIL_ADDRESS_RESOLVED} yet."
            log_error "  Authorisation is a browser sign-in and happens exactly once:"
            log_error ""
            log_error "    journalctl -u $(mailproxy_unit_name) -n 50"
            log_error ""
            log_error "  The relay prints a URL and a code there. Open the URL on your own"
            log_error "  machine, enter the code, sign in as ${EMAIL_ADDRESS_RESOLVED}, then"
            log_error "  re-run this provisioner."
        fi
        return 1
    fi

    if (( rc == 2 )); then
        log_error "The server refused the password."
        log_error "Where a provider has disabled password authentication for IMAP, the"
        log_error "adapter cannot authenticate directly — it speaks no OAuth2. The way"
        log_error "through is a local OAuth2 relay: point IMAP and SMTP at 127.0.0.1 and"
        log_error "let the relay hold the OAuth credentials."
    fi
    return 1
}

# True when the adapter is pointed at the local relay rather than the provider.
_email_via_relay() {
    is_true "${MAILPROXY_ENABLED:-false}" || return 1
    [[ $EMAIL_IMAP_RESOLVED == "${MAILPROXY_LISTEN}" ]]
}

_channel_whatsapp() {
    is_true "${CHANNEL_WHATSAPP_ENABLED:-false}" || { _channel_disable whatsapp; return 0; }
    log_info "channel        whatsapp (${CHANNEL_WHATSAPP_MODE})"

    if _channel_guard_allowlist whatsapp "${CHANNEL_WHATSAPP_ALLOW_ALL:-false}" "${CHANNEL_WHATSAPP_ALLOWLIST_VAR}"; then
        _env_upsert WHATSAPP_ALLOWED_USERS "$(_allowlist_csv "$(secret_get "$CHANNEL_WHATSAPP_ALLOWLIST_VAR")")"
    fi

    case ${CHANNEL_WHATSAPP_MODE:-bridge} in
        bridge)
            _config_set platforms.whatsapp.enabled true
            _channel_deny_pairing whatsapp
            log_warn "whatsapp bridge: pair by QR after this run — 'hermes gateway setup'"
            log_warn "  Use a number dedicated to the agent. Automation on a personal"
            log_warn "  number risks losing that number."
            ;;
        cloud)
            [[ $TUNNEL_MODE == none ]] &&
                die "whatsapp cloud mode receives webhooks and needs TUNNEL_MODE=api or assisted"
            _env_upsert WHATSAPP_CLOUD_TOKEN "$(secret_require "$CHANNEL_WHATSAPP_TOKEN_VAR" "whatsapp cloud")"
            _env_upsert WHATSAPP_PHONE_NUMBER_ID "$(secret_require "$CHANNEL_WHATSAPP_PHONE_ID_VAR" "whatsapp cloud")"
            _config_set platforms.whatsapp_cloud.enabled true
            ;;
        *) die "unsupported CHANNEL_WHATSAPP_MODE: ${CHANNEL_WHATSAPP_MODE}" ;;
    esac
}

_channel_teams() {
    is_true "${CHANNEL_TEAMS_ENABLED:-false}" || { _channel_disable teams; return 0; }
    log_info "channel        teams"

    # Teams delivers by posting to a public address. Without a tunnel the agent
    # would be configured for a channel that can never reach it.
    [[ $TUNNEL_MODE == none ]] &&
        die "teams receives webhooks and needs TUNNEL_MODE=api or assisted"

    if _channel_guard_allowlist teams "${CHANNEL_TEAMS_ALLOW_ALL:-false}" "${CHANNEL_TEAMS_ALLOWLIST_VAR}"; then
        _env_upsert TEAMS_ALLOWED_USERS "$(_allowlist_csv "$(secret_get "$CHANNEL_TEAMS_ALLOWLIST_VAR")")"
    fi

    # In a dry run the bot's Entra app may not exist yet — the azure module
    # would create it and write the secrets in a real run. Say so, do not fail.
    if [[ $DRY_RUN == true ]] && ! secret_nonempty "$CHANNEL_TEAMS_CLIENT_ID_VAR"; then
        log_info "[dry-run] ${CHANNEL_TEAMS_CLIENT_ID_VAR}/${CHANNEL_TEAMS_CLIENT_SECRET_VAR} are written by the azure module in a real run"
    else
        _env_upsert TEAMS_CLIENT_ID     "$(secret_require "$CHANNEL_TEAMS_CLIENT_ID_VAR" teams)"
        _env_upsert TEAMS_CLIENT_SECRET "$(secret_require "$CHANNEL_TEAMS_CLIENT_SECRET_VAR" teams)"
    fi
    _env_upsert TEAMS_TENANT_ID     "$(secret_require "$CHANNEL_TEAMS_TENANT_ID_VAR" teams)"
    _env_upsert TEAMS_PORT          "${CHANNEL_TEAMS_PORT:-3978}"
    _config_set platforms.teams.enabled true
    _channel_deny_pairing teams
    _channel_teams_toolset

    log_info "teams endpoint https://${BOT_HOSTNAME:-$TUNNEL_HOSTNAME}${TUNNEL_INGRESS_PATH}"
    log_info "  register that as the bot's messaging endpoint if you have not already"
}

# The toolset the agent may use on Teams. Verified against the installed
# release's toolsets.py: a name that does not exist there leaves Teams without
# tools and only a WARNING in the journal to say so.
_channel_teams_toolset() {
    local name=${CHANNEL_TEAMS_TOOLSET:?} reg
    reg="$(hermes_install_dir)/toolsets.py"
    if [[ $DRY_RUN != true ]]; then
        [[ -f $reg ]] || die "cannot verify CHANNEL_TEAMS_TOOLSET: ${reg} not found"
        grep -q "\"${name}\": {" "$reg" ||
            die "CHANNEL_TEAMS_TOOLSET='${name}' is not defined in ${reg}"
    fi
    yaml_merge <<EOF
platform_toolsets:
  teams:
    - ${name}
EOF
}

_channels_restart_if_changed() {
    local unit=${1:-$SERVICE_NAME}
    # Judge by THIS pass's changes, not the run-wide flag: a directory created
    # in the host module is not a reason to restart the gateway here. The
    # service module restarts it for unit and drop-in changes on its own.
    if (( CHANGE_COUNT == ${_CHANNELS_COUNT_BEFORE:-0} )) && ! restart_pending "${unit}.service"; then
        log_skip "no channel changes; not restarting ${unit}"
        return 0
    fi
    [[ $SERVICE_SCOPE == system ]] || return 0
    have_cmd systemctl || return 0
    run systemctl restart "${unit}.service"
    restart_done "${unit}.service"
    log_ok "restarted ${unit} to pick up the new configuration"
}

# shellcheck shell=bash
#
# Configuration: defaults, loading, secret handling, validation.
#
# Sourced, never executed.
#
# The configuration file is sourced (it is bash, and that is what makes it
# expressive). The SECRETS FILE is not: it is parsed line by line, so a token
# containing $, a backtick or a semicolon cannot execute anything.

# ---------------------------------------------------------------------------
# Built-in defaults — the lowest tier of the precedence chain
#   CLI flag > environment > config file > these
#
# Applied with := so anything already set by the environment or an earlier
# config file wins.
# ---------------------------------------------------------------------------
config_defaults() {
    : "${TIMEZONE:=Etc/UTC}"
    : "${FIREWALL_MANAGE:=false}"
    : "${FIREWALL_ALLOW_PORTS:=22}"

    # The account comes from config/bootstrap.conf — the same file bootstrap.sh
    # reads, so the two cannot disagree. Deliberately NOT taken from whoever
    # invoked this: a run must produce the same installation regardless of which
    # account started it.
    : "${SERVICE_USER:=${BOOTSTRAP_USER:-}}"
    : "${SERVICE_GROUP:=${SERVICE_USER}}"
    : "${SERVICE_SCOPE:=system}"
    : "${SERVICE_NAME:=hermes-gateway}"
    : "${SERVICE_HARDEN_NO_NEW_PRIVS:=true}"
    : "${SERVICE_START_LIMIT_INTERVAL:=600}"
    : "${SERVICE_START_LIMIT_BURST:=20}"
    : "${SERVICE_WATCHDOG_SECONDS:=90}"
    : "${SERVICE_ON_FAILURE_UNIT:=}"
    : "${JOURNAL_MAX_USE:=}"
    : "${INSTALL_DIR:=}"
    # The agent's data directory. Derived once, here, from the account home that
    # 40-host.sh enforces — rather than recomputed by each consumer. Three
    # independent derivations are three chances to disagree, and one of them
    # baked an empty value into the generated backup script, where an exported
    # but empty HERMES_HOME is worse than an unset one: it overrides the
    # vendor's own default with nothing.
    if [[ -z ${HERMES_HOME:-} && -n ${SERVICE_USER:-} ]]; then
        HERMES_HOME="${BOOTSTRAP_HOME:-/home/${SERVICE_USER}}/.hermes"
    fi
    : "${HERMES_HOME:=}"

    : "${HERMES_INSTALLER_URL:=https://hermes-agent.nousresearch.com/install.sh}"
    : "${HERMES_REPO:=NousResearch/hermes-agent}"
    : "${HERMES_REF:=}"
    : "${HERMES_REF_KIND:=tag}"
    : "${HERMES_SKIP_BROWSER:=true}"
    : "${HERMES_SKIP_SKILLS:=false}"

    : "${LLM_ENDPOINT_COUNT:=1}"
    : "${LLM_STRATEGY:=single}"
    : "${LLM_CONTEXT_WINDOW:=0}"
    : "${LLM_MAX_OUTPUT:=0}"
    : "${LLM_REASONING_FIELD:=}"
    : "${LLM_VERIFY_TOKEN:=true}"

    : "${TERMINAL_BACKEND:=docker}"
    : "${TERMINAL_DOCKER_IMAGE:=}"
    : "${TERMINAL_IMAGE_PREPULL:=true}"

    : "${DOCKER_MANAGE:=true}"
    : "${DOCKER_APT_URL:=https://download.docker.com/linux/ubuntu}"
    : "${DOCKER_GPG_URL:=https://download.docker.com/linux/ubuntu/gpg}"
    : "${DOCKER_SUITE:=}"
    : "${DOCKER_SUITE_FALLBACK:=noble}"
    : "${DOCKER_LOG_MAX_SIZE:=10m}"
    : "${DOCKER_LOG_MAX_FILE:=3}"
    : "${DOCKER_LIVE_RESTORE:=true}"
    : "${DOCKER_ADDRESS_POOL_BASE:=}"
    : "${DOCKER_ADDRESS_POOL_SIZE:=24}"

    # The bridge to a subscription CLI. Off by default: it presumes a CLI that
    # is installed and signed in for the service account.
    : "${AGY_SHIM_ENABLED:=false}"
    : "${AGY_SHIM_BINARY:=agy}"
    : "${AGY_SHIM_HOST:=127.0.0.1}"
    : "${AGY_SHIM_PORT:=8787}"
    : "${AGY_SHIM_LIB_DIR:=/usr/local/lib/hermes-provisioner}"
    : "${AGY_SHIM_MODELS:=}"
    : "${AGY_SHIM_MODEL_ALIASES:=}"
    : "${AGY_SHIM_UNKNOWN_MODEL:=reject}"
    : "${AGY_SHIM_MAX_CONCURRENT:=3}"
    : "${AGY_SHIM_MAX_PROCESSES:=6}"
    : "${AGY_SHIM_IDLE_TIMEOUT:=900}"
    : "${AGY_SHIM_COMPACT_AT:=120000}"

    : "${MAILPROXY_ENABLED:=false}"
    : "${MAILPROXY_FLOW:=device}"
    : "${MAILPROXY_SCOPES:=IMAP.AccessAsUser.All SMTP.Send}"   # Exchange Online delegated scopes the relay signs in with
    : "${MAILPROXY_LISTEN:=127.0.0.1}"
    : "${MAILPROXY_IMAP_PORT:=1993}"
    : "${MAILPROXY_SMTP_PORT:=1587}"
    : "${MAILPROXY_VENV:=/opt/hermes-mailproxy}"
    : "${MAILPROXY_CERT:=}"
    : "${MAILPROXY_KEY:=}"
    : "${MAILPROXY_STATE_DIR:=/var/lib/hermes-mailproxy}"
    : "${MAILPROXY_TENANT_ID_VAR:=AZURE_TENANT_ID}"
    : "${MAILPROXY_CLIENT_ID_VAR:=MAIL_CLIENT_ID}"
    : "${MAILPROXY_CLIENT_SECRET_VAR:=MAIL_CLIENT_SECRET}"

    : "${CREDENTIALS_DIR:=}"
    : "${CREDENTIAL_FILES:=}"

    : "${GIT_MANAGE:=false}"
    : "${GIT_USER_NAME:=}"
    : "${GIT_USER_EMAIL:=}"
    : "${GIT_DEFAULT_BRANCH:=main}"
    : "${GIT_PULL_REBASE:=true}"
    : "${GIT_EDITOR:=true}"
    : "${GIT_PAGER:=cat}"
    : "${GIT_CONFLICT_STYLE:=zdiff3}"
    : "${GIT_SIGNING_KEY:=}"
    : "${GIT_SAFE_DIRECTORIES:=}"
    : "${GIT_EXTRA_CONFIG:=}"
    : "${GIT_SSH_MANAGE:=false}"
    : "${GIT_SSH_KEY_TYPE:=ed25519}"
    : "${GIT_SSH_KEY_COMMENT:=}"
    : "${GIT_SSH_HOSTS:=}"
    : "${GIT_FORCE_SSH:=false}"

    : "${CLIS_MANAGE:=false}"
    : "${CLIS_INSTALL:=}"
    : "${CLI_URL_AGY:=}"
    : "${CLI_URL_CLAUDE:=}"

    : "${DEVTOOLS_MANAGE:=false}"
    : "${DEVTOOLS_BIN_DIR:=/usr/local/bin}"
    : "${DEVTOOLS_INSTALL:=}"
    : "${DEVTOOLS_GITHUB_TOKEN_VAR:=}"

    : "${TUNNEL_MODE:=none}"
    : "${TUNNEL_PROVIDER:=cloudflare}"
    : "${TUNNEL_NAME:=}"
    : "${TUNNEL_HOSTNAME:=}"
    : "${TUNNEL_ZONE:=}"
    : "${TUNNEL_INGRESS_TARGET:=http://127.0.0.1:3978}"
    : "${TUNNEL_INGRESS_PATH:=/api/messages}"
    : "${TUNNEL_API_TOKEN_VAR:=CF_API_TOKEN}"

    # --- azure: the Bot Service in front of Teams, declared in Bicep ----------
    : "${AZURE_MANAGE:=false}"
    : "${AZURE_SUBSCRIPTION_ID:=}"
    : "${AZURE_RESOURCE_GROUP:=}"
    : "${AZURE_LOCATION:=westeurope}"
    : "${AZURE_BOT_SKU:=F0}"
    : "${AZURE_BOT_RECREATE:=false}"           # one run: delete a bot whose immutable identity differs
    : "${AZURE_TENANT_ID_VAR:=AZURE_TENANT_ID}"
    : "${AZURE_MAIL_APP_ID_VAR:=MAIL_CLIENT_ID}"
    # Derived, with no literal fallback: config_defaults runs once before the
    # files are loaded and once after, and a literal here would be locked in by
    # the first pass. Empty stays empty; the package build refuses a hole.
    : "${TEAMS_APP_DEVELOPER:=${GIT_USER_NAME:-}}"
    # The vendor's default names a "hermes-teams" toolset that this release
    # does not define, so Teams would run without tools. Any defined platform
    # toolset works; hermes-telegram is the core set with no platform extras.
    : "${CHANNEL_TEAMS_TOOLSET:=hermes-telegram}"
    # Fail-closed by default. Exchange Online stamps Authentication-Results on
    # inbound external mail but not on mail between mailboxes of the same
    # tenant, so a tenant-internal operator must switch this off.
    : "${CHANNEL_EMAIL_REQUIRE_AUTHENTICATED_SENDER:=true}"

    # --- assistant: MCP servers that give the agent hands in M365 (and Google) --
    : "${ASSISTANT_M365_ENABLED:=false}"
    : "${ASSISTANT_M365_ACCOUNT:=}"                   # the account the server acts as
    : "${ASSISTANT_M365_CLIENT_ID_VAR:=MAIL_CLIENT_ID}"
    : "${ASSISTANT_M365_TENANT_ID_VAR:=AZURE_TENANT_ID}"
    : "${ASSISTANT_M365_TIMEZONE:=Europe/Zurich}"
    : "${ASSISTANT_M365_SCOPES:=offline_access openid profile User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite OnlineMeetings.ReadWrite Files.ReadWrite}"
    # The operator's own mailboxes in the tenant the assistant may READ
    # (receipts, invoices, letters) — search, read, attachments, folders; never
    # send, move or mark. Each needs Full Access delegation for the assistant's
    # account on the Exchange side (README 1.10); the scope it needs is added
    # here, declared and consented by the azure module.
    : "${ASSISTANT_M365_READ_MAILBOXES:=}"
    if [[ -n ${ASSISTANT_M365_READ_MAILBOXES} && " ${ASSISTANT_M365_SCOPES} " != *" Mail.Read.Shared "* ]]; then
        ASSISTANT_M365_SCOPES+=" Mail.Read.Shared"
    fi
    : "${ASSISTANT_STATE_DIR:=/var/lib/hermes-assistant}"
    : "${ASSISTANT_LIB_DIR:=/usr/local/lib/hermes-assistant}"
    : "${ASSISTANT_VENV:=${ASSISTANT_STATE_DIR}/venv}"
    : "${ASSISTANT_PYPDF_VERSION:=6.17.0}"
    : "${ASSISTANT_DOCX_VERSION:=1.2.0}"
    : "${ASSISTANT_LOGIN_TIMEOUT:=900}"
    : "${ASSISTANT_M365_ROOT_FOLDER:=Secretary}"     # the agent's working folder in its OneDrive
    : "${ASSISTANT_M365_SHARE_WITH:=}"                # comma-separated people who get access to it
    : "${ASSISTANT_M365_SHARE_ROLE:=write}"

    # --- assistant, Google side: the private account -------------------------
    : "${ASSISTANT_GOOGLE_ENABLED:=false}"
    : "${ASSISTANT_GOOGLE_ACCOUNT:=}"                 # the Gmail account the server acts as
    : "${GOOGLE_PROJECT:=}"                           # the Cloud project holding the OAuth client
    : "${GOOGLE_APIS:=gmail calendar-json drive people}"
    : "${ASSISTANT_GOOGLE_CLIENT_ID_VAR:=GOOGLE_OAUTH_CLIENT_ID}"
    : "${ASSISTANT_GOOGLE_CLIENT_SECRET_VAR:=GOOGLE_OAUTH_CLIENT_SECRET}"
    : "${ASSISTANT_GOOGLE_TIMEZONE:=${ASSISTANT_M365_TIMEZONE}}"
    : "${ASSISTANT_GOOGLE_SCOPES:=openid email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive}"
    # The operator's own Gmail accounts the assistant may READ: one read-only
    # sign-in each, AS that account, with these scopes only (README 1.11).
    : "${ASSISTANT_GOOGLE_READ_ACCOUNTS:=}"
    : "${ASSISTANT_GOOGLE_READ_SCOPES:=openid email https://www.googleapis.com/auth/gmail.readonly}"

    # --- assistant, GitHub side: the official GitHub MCP server ---------------
    : "${ASSISTANT_GITHUB_ENABLED:=false}"
    : "${ASSISTANT_GITHUB_TOKEN_VAR:=GITHUB_MCP_TOKEN}"  # a personal access token in the secrets file
    : "${ASSISTANT_GITHUB_MCP_VERSION:=1.12.0}"          # github/github-mcp-server release
    : "${ASSISTANT_GITHUB_TOOLSETS:=context,repos,issues,pull_requests,actions,code_security,discussions,notifications,users,labels}"
    : "${ASSISTANT_GITHUB_READ_ONLY:=false}"

    # --- bots: one Teams bot per role, each its own profile, service, hostname --
    : "${BOTS:=}"                          # space-separated keys, lowercase, e.g. "secretary search news"
    : "${BOT_PREFIX:=}"                    # display names are "<prefix> <Name>"
    : "${BOT_SERVICE_PREFIX:=agent}"       # units <prefix>-<key>.service, Azure bots <prefix>-<key>
    : "${BOT_PORT_BASE:=3978}"             # webhook ports: base, base+1, … unless a bot names its own
    # --- public site: home, privacy, terms — what the OAuth providers ask for ---
    : "${SITE_ENABLED:=false}"
    # Derived without a literal: config_defaults runs before AND after the
    # files load; set only once the zone is known, or "assistant." is locked in.
    [[ -n ${TUNNEL_ZONE:-} ]] && : "${SITE_HOSTNAME:=assistant.${TUNNEL_ZONE}}"
    : "${SITE_HOSTNAME:=}"
    : "${SITE_PORT:=8081}"
    : "${SITE_ROOT:=/var/www/assistant-site}"
    : "${SITE_OWNER:=}"                     # legal name shown on the pages
    : "${SITE_CONTACT:=}"                   # contact address shown on the pages
    # When a chat starts over with an empty transcript: none | daily@HOUR | idle@MINUTES.
    # Memory, files, calendar and cron jobs live outside the transcript and survive.
    : "${AGENT_SESSION_RESET:=none}"
    : "${TUNNEL_PROTOCOL:=}"
    : "${TUNNEL_START_TIMEOUT:=90}"
    : "${TUNNEL_TOKEN_FILE:=/etc/cloudflared/token}"
    : "${TUNNEL_EDGE_TLS_WAIT:=300}"
    : "${TUNNEL_ACCOUNT_ID_VAR:=CF_ACCOUNT_ID}"

    : "${BACKUP_MANAGE:=true}"
    : "${BACKUP_DEST:=}"
    : "${BACKUP_ON_CALENDAR:=daily}"
    : "${BACKUP_RANDOM_DELAY:=1h}"
    : "${BACKUP_KEEP:=14}"

    : "${SECRETS_FILE:=}"
    : "${LOG_LEVEL:=info}"
    : "${ASSUME_YES:=false}"

    # Where the provisioner records what it did: the resolved revision, so a
    # re-run can tell "already at the pinned commit" from "needs installing".
    : "${PROVISIONER_STATE_DIR:=/var/lib/hermes-provisioner}"

    : "${DASHBOARD_ENABLED:=false}"
    : "${DASHBOARD_PORT:=9119}"
    : "${DASHBOARD_PROXY:=false}"
    : "${DASHBOARD_PROXY_BIND:=127.0.0.1}"
    : "${DASHBOARD_ENV_FILE:=/etc/hermes-dashboard.env}"
    : "${DASHBOARD_PROXY_AUTH:=true}"
    : "${DASHBOARD_PROXY_PORT:=80}"
    : "${DASHBOARD_PROXY_USER:=admin}"
    : "${DASHBOARD_PROXY_PASSWORD_VAR:=DASHBOARD_PASSWORD}"

    : "${CHANNELS_UNATTENDED_MODE:=deny}"
    : "${CHANNELS_CRON_MODE:=deny}"
    : "${CHANNELS_APPROVALS_DENY:=}"
}

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

# config_load FILE...
#
# Sourcing a config file executes it. That is acceptable for a file the operator
# wrote and owns, and is checked here: refusing group- or world-writable files
# stops the obvious escalation where a less privileged user edits the config a
# root provisioner will source.
config_load() {
    local file
    for file in "$@"; do
        [[ -n $file ]] || continue
        if [[ ! -f $file ]]; then
            # Not skipped. A run that silently proceeds without a configuration
            # file does whatever the built-in defaults say, reports success, and
            # leaves the operator believing their settings were applied.
            log_error "no configuration at ${file}"
            log_error "  copy the matching .example, or point at another file with --config"
            die "missing configuration"
        fi
        _assert_not_writable_by_others "$file"
        log_debug "loading config: $file"
        # shellcheck disable=SC1090
        source "$file"
    done
}

_assert_not_writable_by_others() {
    local file=$1 mode
    mode=$(stat -c '%a' "$file" 2>/dev/null) || die "cannot stat $file"
    # Any group- or other-write bit set.
    if (( 8#$mode & 8#022 )); then
        # Sourcing runs the file as root. A group- or world-writable config is a
        # way for a less privileged account to inject code into that run.
        #
        # This bites on a fresh clone: git records only the executable bit, so a
        # checkout under umask 002 lands at 664. Name the remedy rather than
        # leaving it as an exercise.
        log_error "$file is writable by group or others (mode $mode)"
        log_error "  it is sourced as root, so that is an injection point. Fix with:"
        log_error "    chmod 0644 $file"
        die "refusing to source a writable configuration file"
    fi
}

# ---------------------------------------------------------------------------
# Secrets
#
# Parsed, never sourced. Accepts KEY=value and KEY="value", ignores comments and
# blank lines, and rejects anything else rather than guessing.
# ---------------------------------------------------------------------------

declare -gA _SECRETS=()

secrets_load() {
    local file=${SECRETS_FILE:-}
    [[ -n $file ]] || die "SECRETS_FILE is not set"
    [[ -f $file ]] || die "SECRETS_FILE does not exist: $file"

    local mode
    mode=$(stat -c '%a' "$file") || die "cannot stat $file"
    if (( 8#$mode & 8#077 )); then
        die "$file must not be readable or writable by group or others (mode $mode); chmod 0600"
    fi

    local line key value lineno=0
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$(( lineno + 1 ))
        [[ -z ${line//[[:space:]]/} ]] && continue
        [[ ${line#"${line%%[![:space:]]*}"} == '#'* ]] && continue

        if [[ ! $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            die "$file:$lineno is not a KEY=value assignment"
        fi
        key=${BASH_REMATCH[2]}
        value=${BASH_REMATCH[3]}

        # Strip one layer of matching quotes; take the rest literally.
        if [[ $value == \"*\" && ${#value} -ge 2 ]]; then
            value=${value:1:${#value}-2}
        elif [[ $value == \'*\' && ${#value} -ge 2 ]]; then
            value=${value:1:${#value}-2}
        fi

        _SECRETS["$key"]=$value
        log_redact_register "$value"
    done <"$file"

    log_debug "loaded ${#_SECRETS[@]} secrets from $file"
}

# secret_get KEY -> value on stdout; fails if absent.
#
# An empty key is "no credential configured", not a lookup: an associative
# array subscript of "" is a runtime error, which under errexit aborts the run
# rather than returning a miss.
secret_get() {
    local key=${1:-}
    [[ -n $key ]] || return 1
    [[ -n ${_SECRETS[$key]+set} ]] || return 1
    printf '%s' "${_SECRETS[$key]}"
}

# Present at all — which is not the same as usable.
secret_has() { [[ -n ${1:-} ]] && [[ -n ${_SECRETS[$1]+set} ]]; }

# Present AND carries a value. A half-filled credentials file is the normal
# state during setup, and an empty value that passes validation only to fail
# deep inside a run is the worst of both.
secret_nonempty() { [[ -n ${1:-} ]] && [[ -n ${_SECRETS[$1]:-} ]]; }

# secret_require KEY CONTEXT — fail by name, naming what needed it.
secret_require() {
    local key=$1 context=$2
    secret_has "$key" ||
        die "secret '$key' is required by $context but is not in $SECRETS_FILE"
    secret_nonempty "$key" ||
        die "secret '$key' is required by $context but is empty in $SECRETS_FILE"
    secret_get "$key"
}

# ---------------------------------------------------------------------------
# Validation
#
# Every check runs before anything mutates the system, and every failure names
# the setting and the legal values. A provisioner that dies half way through
# because of a typo is worse than one that refuses to start.
# ---------------------------------------------------------------------------

_invalid=()

_bad() { _invalid+=("$1"); }

# A run installs everything the configuration enables, so everything the
# configuration enables gets validated. Each _validate_* already returns early
# when its own feature is switched off.
_validating() { :; }

_check_enum() {
    local name=$1 value=$2; shift 2
    local allowed=("$@") a
    for a in "${allowed[@]}"; do
        [[ $value == "$a" ]] && return 0
    done
    _bad "$name='$value' is not one of: $(join_by ', ' "${allowed[@]}")"
}

_check_required() {
    local name=$1 value=$2 why=${3:-}
    [[ -n $value ]] || _bad "$name is required${why:+ ($why)}"
}

# A list of other people's mailboxes the assistant may read: addresses, none
# of them the assistant's own (that one it reads anyway).
_check_read_accounts() {          # _check_read_accounts NAME VALUE OWN_ACCOUNT
    local IFS=$' ,\t\n' a
    for a in $2; do
        [[ $a == *@* ]] || _bad "${1}: '${a}' is not an address"
        [[ ${a,,} != "${3,,}" ]] || _bad "${1}: ${a} is the assistant's own account; only other mailboxes belong here"
    done
}

# BOT_<KEY>_DELEGATION_ENDPOINT names a global LLM_ENDPOINT_n for the bot's
# sub-agents. Only two shapes can be written without a key landing in
# config.yaml: a keyless custom endpoint (the bridge) or a hosted provider,
# whose key goes to the variable the agent expects. A custom endpoint with a
# key is refused rather than copied.
_check_delegation_endpoint() {    # _check_delegation_endpoint KEY
    local k=$1 n provider model tv
    n=$(bot_field "$k" DELEGATION_ENDPOINT)
    [[ -n $n ]] || return 0
    local var; var="BOT_$(bot_upper "$k")_DELEGATION_ENDPOINT"
    [[ $n =~ ^[0-9]+$ && $n -ge 1 && $n -le ${LLM_ENDPOINT_COUNT:-0} ]] ||
        { _bad "bot ${k}: ${var}=${n} is not one of LLM_ENDPOINT_1..${LLM_ENDPOINT_COUNT:-0}"; return 0; }
    model=$(endpoint_field "$n" MODEL)
    [[ -n $model ]] || _bad "bot ${k}: ${var}=${n} points at an endpoint without LLM_ENDPOINT_${n}_MODEL"
    [[ -n $(bot_field "$k" LLM_MODEL) ]] ||
        _bad "bot ${k}: ${var} without BOT_$(bot_upper "$k")_LLM_MODEL is pointless; sub-agents inherit the bot's model anyway"
    provider=$(endpoint_field "$n" PROVIDER); provider=${provider:-custom}
    tv=$(endpoint_field "$n" TOKEN_VAR)
    if [[ $provider == custom ]]; then
        [[ -z $tv ]] || _bad "bot ${k}: ${var}=${n} is a custom endpoint with a key (${tv}); the delegation block cannot carry a key without writing it into config.yaml — only the keyless bridge or a hosted provider"
    else
        _provider_key_var "$provider" >/dev/null 2>&1 || _bad "bot ${k}: ${var}=${n} names the unknown provider '${provider}'"
        if [[ -z $tv ]] || ! secret_nonempty "$tv"; then
            _bad "bot ${k}: ${var}=${n} (${provider}) needs LLM_ENDPOINT_${n}_TOKEN_VAR naming a present secret"
        fi
    fi
}

_check_abs_path() {
    local name=$1 value=$2
    [[ -z $value || $value == /* ]] || _bad "$name must be an absolute path, got '$value'"
}

config_validate() {
    _invalid=()

    _check_enum SERVICE_SCOPE "$SERVICE_SCOPE" system user
    _check_enum LLM_STRATEGY "$LLM_STRATEGY" single failover
    _check_enum TERMINAL_BACKEND "$TERMINAL_BACKEND" docker local ssh
    _check_enum TUNNEL_MODE "$TUNNEL_MODE" api assisted none
    _check_enum HERMES_REF_KIND "$HERMES_REF_KIND" tag branch commit
    _check_enum LOG_LEVEL "$LOG_LEVEL" debug info warn error
    _check_enum CHANNELS_UNATTENDED_MODE "$CHANNELS_UNATTENDED_MODE" deny ask allow
    _check_enum CHANNELS_CRON_MODE "$CHANNELS_CRON_MODE" deny ask allow

    _check_required SERVICE_USER "$SERVICE_USER" "set BOOTSTRAP_USER in config/bootstrap.conf"
    _bots_validate
    if is_true "${SITE_ENABLED:-false}"; then
        _check_required SITE_OWNER "${SITE_OWNER:-}" "the operator's name on the public pages"
        _check_required SITE_CONTACT "${SITE_CONTACT:-}" "the contact address on the public pages"
        [[ -n ${TUNNEL_ZONE:-} || ${SITE_HOSTNAME:-} == *.* ]] || _bad "SITE_ENABLED=true needs TUNNEL_ZONE or SITE_HOSTNAME"
    fi
    _check_session_reset AGENT_SESSION_RESET "$AGENT_SESSION_RESET"
    if is_true "${ASSISTANT_GITHUB_ENABLED:-false}"; then
        [[ ${ASSISTANT_GITHUB_MCP_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || _bad "ASSISTANT_GITHUB_MCP_VERSION must be X.Y.Z"
    fi
    if is_true "${ASSISTANT_GOOGLE_ENABLED:-false}"; then
        _check_required ASSISTANT_GOOGLE_ACCOUNT "${ASSISTANT_GOOGLE_ACCOUNT:-}" "the Google account the assistant acts as"
        [[ ${ASSISTANT_GOOGLE_ACCOUNT:-} == *@* ]] || _bad "ASSISTANT_GOOGLE_ACCOUNT must be a sign-in address"
        _check_required GOOGLE_PROJECT "${GOOGLE_PROJECT:-}" "the Cloud project holding the OAuth client"
        _check_read_accounts ASSISTANT_GOOGLE_READ_ACCOUNTS "${ASSISTANT_GOOGLE_READ_ACCOUNTS:-}" "${ASSISTANT_GOOGLE_ACCOUNT:-}"
    fi
    if is_true "${ASSISTANT_M365_ENABLED:-false}"; then
        _check_required ASSISTANT_M365_ACCOUNT "${ASSISTANT_M365_ACCOUNT:-}" "the account the M365 assistant acts as"
        [[ ${ASSISTANT_M365_ACCOUNT:-} == *@* ]] || _bad "ASSISTANT_M365_ACCOUNT must be a sign-in address, got '${ASSISTANT_M365_ACCOUNT:-}'"
        _check_read_accounts ASSISTANT_M365_READ_MAILBOXES "${ASSISTANT_M365_READ_MAILBOXES:-}" "${ASSISTANT_M365_ACCOUNT:-}"
    fi
    _check_required SECRETS_FILE "$SECRETS_FILE" "every credential is referenced from it"
    _check_abs_path SECRETS_FILE "$SECRETS_FILE"
    _check_abs_path DEVTOOLS_BIN_DIR "$DEVTOOLS_BIN_DIR"

    # A pointer that names nothing is worse than no pointer: the run falls back
    # to unauthenticated calls and then fails on a rate limit while the
    # configuration says a token is in use.
    if [[ -n ${DEVTOOLS_GITHUB_TOKEN_VAR:-} ]]; then
        secret_nonempty "$DEVTOOLS_GITHUB_TOKEN_VAR" ||
            _bad "DEVTOOLS_GITHUB_TOKEN_VAR names '${DEVTOOLS_GITHUB_TOKEN_VAR}', which is empty or absent in SECRETS_FILE"
    fi
    _check_abs_path INSTALL_DIR "$INSTALL_DIR"
    _check_abs_path HERMES_HOME "$HERMES_HOME"

    _check_required HERMES_REF "$HERMES_REF" "pin a revision rather than tracking a branch"

    if [[ $SERVICE_SCOPE == system ]] && ! is_root && [[ $DRY_RUN != true ]]; then
        _bad "SERVICE_SCOPE=system requires root"
    fi

    _validate_endpoints
    _validate_mailproxy
    _validate_agyshim
    _validate_channels
    _validate_dashboard
    _validate_tunnel
    _validate_backup

    if (( ${#_invalid[@]} )); then
        log_error "configuration is not valid:"
        local problem
        for problem in "${_invalid[@]}"; do
            log_error "  - $problem"
        done
        die "refusing to change anything until the configuration is fixed"
    fi

    log_ok "configuration valid"
}

_validate_endpoints() {
    [[ $LLM_ENDPOINT_COUNT =~ ^[0-9]+$ ]] || { _bad "LLM_ENDPOINT_COUNT must be a number"; return; }
    (( LLM_ENDPOINT_COUNT >= 1 )) || { _bad "LLM_ENDPOINT_COUNT must be at least 1"; return; }

    if [[ $LLM_STRATEGY == failover ]] && (( LLM_ENDPOINT_COUNT < 2 )); then
        _bad "LLM_STRATEGY=failover needs at least two endpoints"
    fi

    local i base model token provider
    for (( i = 1; i <= LLM_ENDPOINT_COUNT; i++ )); do
        provider=$(endpoint_field "$i" PROVIDER); provider=${provider:-custom}
        base=$(endpoint_field "$i" BASE_URL)
        model=$(endpoint_field "$i" MODEL)
        token=$(endpoint_field "$i" TOKEN_VAR)

        _check_required "LLM_ENDPOINT_${i}_MODEL" "$model"

        # base_url identifies a self-hosted endpoint. A hosted provider is
        # identified by name and must NOT carry one.
        if [[ $provider == custom ]]; then
            _check_required "LLM_ENDPOINT_${i}_BASE_URL" "$base" "provider is custom"
            # A loopback endpoint needs no credential: nothing outside this host
            # can reach it, and inventing a token would only be ceremony.
            case $base in
                http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*) ;;
                *) _check_required "LLM_ENDPOINT_${i}_TOKEN_VAR" "$token" ;;
            esac
        elif [[ -n $base ]]; then
            _bad "LLM_ENDPOINT_${i}_BASE_URL is set but the provider is '${provider}', not custom"
        fi

        [[ -z $base || $base == https://* || $base == http://127.0.0.1* || $base == http://localhost* ]] ||
            _bad "LLM_ENDPOINT_${i}_BASE_URL must use https (or plain http only on loopback)"

        # A slot whose key is absent is treated as "prepared but not activated"
        # rather than an error, so cloud providers can sit in the config until
        # a key exists for them.
        # An endpoint that declares no credential is not missing one.
        if [[ -n $token ]] && ! secret_nonempty "$token"; then
            if [[ $provider == custom ]]; then
                if secret_has "$token"; then
                    _bad "LLM_ENDPOINT_${i}_TOKEN_VAR names '$token', which is empty in SECRETS_FILE"
                else
                    _bad "LLM_ENDPOINT_${i}_TOKEN_VAR names '$token', which is not in SECRETS_FILE"
                fi
            else
                _bad "LLM_ENDPOINT_${i} (${provider}) names '${token}', which has no value in SECRETS_FILE"
            fi
        fi
    done
    return 0
}

# endpoint_field INDEX FIELD -> value of LLM_ENDPOINT_<INDEX>_<FIELD>
endpoint_field() {
    local var="LLM_ENDPOINT_${1}_${2}"
    printf '%s' "${!var:-}"
}

_validate_tunnel() {
    _validating tunnel || return 0
    [[ $TUNNEL_MODE == none ]] && return 0

    _check_enum TUNNEL_PROVIDER "$TUNNEL_PROVIDER" cloudflare
    _check_required TUNNEL_HOSTNAME "$TUNNEL_HOSTNAME" "the public name the platform posts to"
    _check_required TUNNEL_NAME "$TUNNEL_NAME"
    _check_required TUNNEL_ZONE "$TUNNEL_ZONE" "needed to place the DNS record"

    [[ $TUNNEL_INGRESS_PATH == /* ]] || _bad "TUNNEL_INGRESS_PATH must start with /"

    if [[ $TUNNEL_MODE == api ]]; then
        secret_nonempty "$TUNNEL_API_TOKEN_VAR" ||
            _bad "TUNNEL_MODE=api needs a non-empty '$TUNNEL_API_TOKEN_VAR' in SECRETS_FILE"
        secret_nonempty "$TUNNEL_ACCOUNT_ID_VAR" ||
            _bad "TUNNEL_MODE=api needs a non-empty '$TUNNEL_ACCOUNT_ID_VAR' in SECRETS_FILE"
    fi

    if [[ -n $TUNNEL_HOSTNAME && -n $TUNNEL_ZONE && $TUNNEL_HOSTNAME != *"$TUNNEL_ZONE" ]]; then
        _bad "TUNNEL_HOSTNAME '$TUNNEL_HOSTNAME' is not inside TUNNEL_ZONE '$TUNNEL_ZONE'"
    fi
    return 0
}

# Channel credentials are checked here rather than when each channel is reached.
# Reaching the channels means the host, the tunnel, the runtime, the agent and
# the service have already been applied; discovering a blank password at that
# point costs ten minutes instead of ten seconds.
_validate_mailproxy() {
    _validating mailproxy || return 0
    is_true "${MAILPROXY_ENABLED:-false}" || return 0

    _check_enum MAILPROXY_FLOW "$MAILPROXY_FLOW" device client_credentials
    _check_abs_path MAILPROXY_VENV "$MAILPROXY_VENV"
    _check_abs_path MAILPROXY_STATE_DIR "$MAILPROXY_STATE_DIR"
    _check_required CHANNEL_EMAIL_WORK_ADDRESS "${CHANNEL_EMAIL_WORK_ADDRESS:-}" "the relay serves that mailbox"
    _require_secret_for "$MAILPROXY_TENANT_ID_VAR" "the mail relay"
    _require_secret_for "$MAILPROXY_CLIENT_ID_VAR" "the mail relay"
    [[ $MAILPROXY_FLOW == client_credentials ]] &&
        _require_secret_for "$MAILPROXY_CLIENT_SECRET_VAR" "the client-credentials flow"

    # The relay exists to serve the work mailbox. Enabling one without the other
    # is a configuration that runs and does nothing useful.
    if is_true "${CHANNEL_EMAIL_ENABLED:-false}" && [[ ${CHANNEL_EMAIL_ACCOUNT:-} != work ]]; then
        _bad "MAILPROXY_ENABLED=true but CHANNEL_EMAIL_ACCOUNT is '${CHANNEL_EMAIL_ACCOUNT:-}' — the relay only serves the work mailbox"
    fi
    return 0
}

_validate_agyshim() {
    _validating agyshim || return 0
    is_true "${AGY_SHIM_ENABLED:-false}" || return 0
    _check_enum AGY_SHIM_UNKNOWN_MODEL "$AGY_SHIM_UNKNOWN_MODEL" reject default
    _check_required AGY_SHIM_MODELS "$AGY_SHIM_MODELS" "the bridge needs an explicit model allowlist"
    _check_abs_path AGY_SHIM_LIB_DIR "$AGY_SHIM_LIB_DIR"
    [[ $AGY_SHIM_HOST == 0.0.0.0 ]] &&
        _bad "AGY_SHIM_HOST=0.0.0.0 publishes an unauthenticated model endpoint on every interface"
    return 0
}

_validate_channels() {
    _validating channels || return 0
    local name upper var
    for name in telegram email whatsapp teams; do
        upper=${name^^}
        var="CHANNEL_${upper}_ENABLED"
        is_true "${!var:-false}" || continue

        var="CHANNEL_${upper}_ALLOW_ALL"
        if ! is_true "${!var:-false}"; then
            var="CHANNEL_${upper}_ALLOWLIST_VAR"
            _require_secret_for "${!var:-}" "the ${name} allowlist"
        fi

        case $name in
            telegram) _require_secret_for "${CHANNEL_TELEGRAM_TOKEN_VAR:-}" "telegram" ;;
            email)
                local which=${CHANNEL_EMAIL_ACCOUNT:-}
                if [[ $which != private && $which != work ]]; then
                    _bad "CHANNEL_EMAIL_ACCOUNT must be 'private' or 'work', got '${which}'"
                else
                    local u=${which^^} k
                    for k in ADDRESS IMAP_HOST SMTP_HOST; do
                        local var="CHANNEL_EMAIL_${u}_${k}"
                        _check_required "$var" "${!var:-}" "the ${which} mailbox"
                    done
                    local pv="CHANNEL_EMAIL_${u}_PASSWORD_VAR"
                    _require_secret_for "${!pv:-}" "the ${which} mailbox"
                fi
                ;;
            teams)
                _require_secret_for "${CHANNEL_TEAMS_CLIENT_ID_VAR:-}" "teams"
                _require_secret_for "${CHANNEL_TEAMS_CLIENT_SECRET_VAR:-}" "teams"
                _require_secret_for "${CHANNEL_TEAMS_TENANT_ID_VAR:-}" "teams"
                [[ $TUNNEL_MODE == none ]] &&
                    _bad "the teams channel receives webhooks and needs TUNNEL_MODE=api or assisted"
                ;;
            whatsapp)
                if [[ ${CHANNEL_WHATSAPP_MODE:-bridge} == cloud ]]; then
                    _require_secret_for "${CHANNEL_WHATSAPP_TOKEN_VAR:-}" "whatsapp cloud"
                    _require_secret_for "${CHANNEL_WHATSAPP_PHONE_ID_VAR:-}" "whatsapp cloud"
                    [[ $TUNNEL_MODE == none ]] &&
                        _bad "whatsapp cloud mode receives webhooks and needs a tunnel"
                fi
                ;;
        esac
    done
    return 0
}

_require_secret_for() {
    local key=$1 what=$2
    [[ -n $key ]] || { _bad "${what} has no secret variable configured"; return 0; }
    if ! secret_has "$key"; then
        _bad "${what} needs '${key}', which is not in SECRETS_FILE"
    elif ! secret_nonempty "$key"; then
        _bad "${what} needs '${key}', which is empty in SECRETS_FILE"
    fi
    return 0
}

_validate_dashboard() {
    _validating dashboard || return 0
    is_true "${DASHBOARD_ENABLED:-false}" || return 0
    is_true "${DASHBOARD_PROXY:-false}"   || return 0

    _check_required DASHBOARD_PROXY_BIND "$DASHBOARD_PROXY_BIND"
    _check_required DASHBOARD_PROXY_USER "$DASHBOARD_PROXY_USER"

    # A published dashboard edits API keys, so it may not be published without
    # credentials to hold in front of it.
    secret_nonempty "${DASHBOARD_PROXY_PASSWORD_VAR}" ||
        _bad "DASHBOARD_PROXY=true needs a non-empty '${DASHBOARD_PROXY_PASSWORD_VAR}' in SECRETS_FILE"

    if [[ $DASHBOARD_PROXY_BIND == 0.0.0.0 ]]; then
        _bad "DASHBOARD_PROXY_BIND=0.0.0.0 publishes on every interface; name one address"
    fi
    return 0
}

_validate_backup() {
    _validating backup || return 0
    is_true "$BACKUP_MANAGE" || return 0
    _check_required BACKUP_DEST "$BACKUP_DEST" "BACKUP_MANAGE=true"
    _check_abs_path BACKUP_DEST "$BACKUP_DEST"
    [[ $BACKUP_KEEP =~ ^[0-9]+$ ]] || _bad "BACKUP_KEEP must be a number"
    return 0
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# config_summary — what is about to happen, before it happens. Secrets are
# redacted by the logging layer, but nothing secret is printed here anyway.
config_summary() {
    log_step "Configuration"
    log_info "service        ${SERVICE_NAME} as ${SERVICE_USER} (${SERVICE_SCOPE} scope)"
    log_info "revision       ${HERMES_REF} (${HERMES_REF_KIND})"
    log_info "inference      ${LLM_ENDPOINT_COUNT} endpoint(s), strategy=${LLM_STRATEGY}"
    log_info "sandbox        ${TERMINAL_BACKEND}"
    if is_true "${AGY_SHIM_ENABLED:-false}"; then
        log_info "bridge         ${AGY_SHIM_HOST}:${AGY_SHIM_PORT} via ${AGY_SHIM_BINARY} [${AGY_SHIM_MODELS}]"
    fi
    log_info "docker         manage=${DOCKER_MANAGE}"
    log_info "tunnel         ${TUNNEL_MODE}${TUNNEL_HOSTNAME:+ -> $TUNNEL_HOSTNAME}"
    log_info "backup         manage=${BACKUP_MANAGE}${BACKUP_DEST:+ -> $BACKUP_DEST}"
    if is_true "${DEVTOOLS_MANAGE:-false}"; then
        local n; n=$(printf '%s' "$DEVTOOLS_INSTALL" | wc -w)
        log_info "devtools       ${n} tool(s) -> ${DEVTOOLS_BIN_DIR}"
    fi
    log_info "channels       $(channels_enabled_list)"
    if is_true "${DASHBOARD_ENABLED:-false}"; then
        if is_true "${DASHBOARD_PROXY:-false}"; then
            log_info "dashboard      http://${DASHBOARD_PROXY_BIND}:${DASHBOARD_PROXY_PORT} (proxied, authenticated)"
        else
            log_info "dashboard      127.0.0.1:${DASHBOARD_PORT} (tunnel to reach it)"
        fi
    fi
    [[ $DRY_RUN == true ]] && log_warn "dry run: nothing will be changed"
    return 0
}

# channels_enabled_list -> space-separated names of enabled channels.
channels_enabled_list() {
    local out=() name var
    for name in telegram email whatsapp teams; do
        var="CHANNEL_${name^^}_ENABLED"
        is_true "${!var:-false}" && out+=("$name")
    done
    # Local IFS: the script sets IFS to newline/tab, which "${out[*]}" would
    # otherwise use as the separator and print one channel per line.
    local IFS=$' \t\n'
    (( ${#out[@]} )) && printf '%s' "${out[*]}" || printf 'none'
}

# ---------------------------------------------------------------------------
# Bots
#
# A bot is a key in BOTS. Everything about it is BOT_<KEY>_<FIELD> with a
# default derived from the key, so a new bot is one word in BOTS plus whatever
# it needs that differs. bot_context KEY exports the bot's values under fixed
# names (BOT_KEY, BOT_NAME, BOT_HOME, …) and points the agent's configuration
# helpers at the bot's profile; modules loop `for key in $(bots)`.
# ---------------------------------------------------------------------------
bots() {                    # the keys, one per line, in configured order
    local IFS=$' \t\n' k
    for k in ${BOTS:-}; do printf '%s\n' "$k"; done
}

bot_count() { bots | grep -c . || true; }

bot_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

bot_index() {               # 0-based position of KEY in BOTS
    local i=0 k
    while IFS= read -r k; do
        [[ $k == "$1" ]] && { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done < <(bots)
    return 1
}

# bot_field KEY FIELD -> the configured BOT_<KEY>_<FIELD>, or its default
bot_field() {
    local key=$1 field=$2 var name
    var="BOT_$(bot_upper "$1")_${2}"
    if [[ -n ${!var+set} ]]; then printf '%s' "${!var}"; return 0; fi
    name="$(tr '[:lower:]' '[:upper:]' <<<"${key:0:1}")${key:1}"
    case $field in
        NAME)          printf '%s' "$name" ;;
        DISPLAY_NAME)  printf '%s' "${BOT_PREFIX:+${BOT_PREFIX} }$(bot_field "$key" NAME)" ;;
        DESCRIPTION)   printf '%s' "$(bot_field "$key" NAME) — a private assistant bot. Only allowlisted people receive answers." ;;
        ROLE)          printf '%s' "$key" ;;
        CHANNELS)      printf 'teams' ;;
        MCP)           printf '' ;;
        PORT)          printf '%s' $(( BOT_PORT_BASE + $(bot_index "$key") )) ;;
        HOSTNAME)      printf '%s.%s' "$key" "${TUNNEL_ZONE:-}" ;;
        SERVICE)       printf '%s-%s' "$BOT_SERVICE_PREFIX" "$key" ;;
        AZURE_NAME)    printf '%s-%s' "$BOT_SERVICE_PREFIX" "$key" ;;
        TEAMS_CLIENT_ID_VAR)     printf 'TEAMS_%s_CLIENT_ID' "$(bot_upper "$key")" ;;
        TEAMS_CLIENT_SECRET_VAR) printf 'TEAMS_%s_CLIENT_SECRET' "$(bot_upper "$key")" ;;
        DASHBOARD)     printf 'false' ;;
        SESSION_RESET) printf '%s' "$AGENT_SESSION_RESET" ;;
        MAIL_ALIAS)    printf '' ;;                     # address on the shared mailbox that reaches this bot
        MAIL_FOLDER)   if [[ -n $(bot_field "$key" MAIL_ALIAS) && $(bot_field "$key" MAIL_CATCH_ALL) != true ]]; then bot_field "$key" NAME; else printf 'INBOX'; fi ;;
        MAIL_CATCH_ALL) printf 'false' ;;               # true: this bot reads INBOX (everything not routed elsewhere)
        LLM_MODEL)     printf '' ;;                     # empty: the global LLM_ENDPOINT_1 applies
        LLM_PROVIDER)  printf 'custom' ;;
        LLM_NAME)      printf '%s-llm' "$key" ;;
        LLM_BASE_URL)  printf '' ;;
        LLM_TOKEN_VAR) printf '' ;;
        LLM_REASONING_FIELD) printf '' ;;
        LLM_CONTEXT_WINDOW)  printf '%s' "${LLM_CONTEXT_WINDOW:-0}" ;;
        DELEGATION_ENDPOINT) printf '' ;;               # LLM_ENDPOINT_n the bot's sub-agents (delegate_task) run on; empty: they inherit the bot's model
        TOOLSET)       printf '%s' "${CHANNEL_TEAMS_TOOLSET:-hermes-telegram}" ;;
        *) die "bot_field: unknown field '${field}'" ;;
    esac
}

bot_has_channel() {         # bot_has_channel KEY CHANNEL
    local IFS=$' \t\n' c
    for c in $(bot_field "$1" CHANNELS); do [[ $c == "$2" ]] && return 0; done
    return 1
}

bot_has_mcp() {             # bot_has_mcp KEY SERVER
    local IFS=$' \t\n' m
    for m in $(bot_field "$1" MCP); do [[ $m == "$2" ]] && return 0; done
    return 1
}

bot_home() { printf '%s/profiles/%s' "$HERMES_HOME" "$1"; }

# bot_context KEY — export the bot under fixed names and point the agent's
# configuration helpers (config.yaml, .env, hermes CLI) at its profile.
# bot_context_end restores the default profile.
bot_context() {
    local key=$1
    bot_index "$key" >/dev/null || die "bot_context: '${key}' is not in BOTS"
    BOT_KEY=$key
    BOT_NAME=$(bot_field "$key" NAME)
    BOT_DISPLAY_NAME=$(bot_field "$key" DISPLAY_NAME)
    BOT_DESCRIPTION=$(bot_field "$key" DESCRIPTION)
    BOT_ROLE=$(bot_field "$key" ROLE)
    BOT_PORT=$(bot_field "$key" PORT)
    BOT_HOSTNAME=$(bot_field "$key" HOSTNAME)
    BOT_SERVICE=$(bot_field "$key" SERVICE)
    BOT_AZURE_NAME=$(bot_field "$key" AZURE_NAME)
    BOT_TEAMS_CLIENT_ID_VAR=$(bot_field "$key" TEAMS_CLIENT_ID_VAR)
    BOT_TEAMS_CLIENT_SECRET_VAR=$(bot_field "$key" TEAMS_CLIENT_SECRET_VAR)
    BOT_HOME=$(bot_home "$key")
    HERMES_CONFIG_HOME=$BOT_HOME
    export BOT_KEY BOT_NAME BOT_DISPLAY_NAME BOT_DESCRIPTION BOT_ROLE BOT_PORT BOT_HOSTNAME \
           BOT_SERVICE BOT_AZURE_NAME BOT_TEAMS_CLIENT_ID_VAR BOT_TEAMS_CLIENT_SECRET_VAR BOT_HOME HERMES_CONFIG_HOME
}

bot_context_end() {
    unset BOT_KEY BOT_NAME BOT_DISPLAY_NAME BOT_DESCRIPTION BOT_ROLE BOT_PORT BOT_HOSTNAME \
          BOT_SERVICE BOT_AZURE_NAME BOT_TEAMS_CLIENT_ID_VAR BOT_TEAMS_CLIENT_SECRET_VAR BOT_HOME
    HERMES_CONFIG_HOME=${HERMES_HOME:-}
}

bot_teams_package() { printf '%s/bot/build/%s-teams-app.zip' "$SCRIPT_DIR" "$1"; }

bot_role_file() { printf '%s/bot/roles/%s.md' "$SCRIPT_DIR" "$(bot_field "$1" ROLE)"; }

# Validation: keys, uniqueness, roles, channels, servers.
_bots_validate() {
    local -a keys=() ports=() hosts=()
    local k p h c m emails=0
    while IFS= read -r k; do
        [[ -n $k ]] || continue
        [[ $k =~ ^[a-z][a-z0-9]{1,23}$ ]] || { _bad "BOTS: '${k}' must be lowercase letters and digits (2-24 chars)"; continue; }
        keys+=("$k")
        p=$(bot_field "$k" PORT); h=$(bot_field "$k" HOSTNAME)
        local other
        for other in ${ports+"${ports[@]}"}; do [[ $other == "$p" ]] && _bad "bots: port ${p} is used twice"; done
        for other in ${hosts+"${hosts[@]}"}; do [[ $other == "$h" ]] && _bad "bots: hostname ${h} is used twice"; done
        ports+=("$p"); hosts+=("$h")
        [[ -f $(bot_role_file "$k") ]] || _bad "bot ${k}: no role file bot/roles/$(bot_field "$k" ROLE).md"
        local IFS=$' \t\n'
        for c in $(bot_field "$k" CHANNELS); do
            case $c in teams) ;; email) emails=$((emails + 1)) ;; *) _bad "bot ${k}: unknown channel '${c}' (teams, email)" ;; esac
        done
        for m in $(bot_field "$k" MCP); do
            case $m in m365)   is_true "${ASSISTANT_M365_ENABLED:-false}"   || _bad "bot ${k}: MCP m365 needs ASSISTANT_M365_ENABLED=true" ;;
                       google) is_true "${ASSISTANT_GOOGLE_ENABLED:-false}" || _bad "bot ${k}: MCP google needs ASSISTANT_GOOGLE_ENABLED=true" ;;
                       github) is_true "${ASSISTANT_GITHUB_ENABLED:-false}" || _bad "bot ${k}: MCP github needs ASSISTANT_GITHUB_ENABLED=true" ;;
                       *) _bad "bot ${k}: unknown MCP server '${m}' (m365, google, github)" ;; esac
        done
        is_true "$(bot_field "$k" DASHBOARD)" && dashboards=$(( ${dashboards:-0} + 1 ))
        _check_session_reset "BOT_$(bot_upper "$k")_SESSION_RESET" "$(bot_field "$k" SESSION_RESET)"
        if [[ -n $(bot_field "$k" LLM_MODEL) ]]; then
            [[ $(bot_field "$k" LLM_PROVIDER) != custom || -n $(bot_field "$k" LLM_BASE_URL) ]] ||
                _bad "bot ${k}: BOT_$(bot_upper "$k")_LLM_BASE_URL is needed for a custom provider"
            local tv; tv=$(bot_field "$k" LLM_TOKEN_VAR)
            [[ -z $tv ]] || secret_nonempty "$tv" || _bad "bot ${k}: secret '${tv}' (its LLM key) is missing or empty in the secrets file"
        fi
        _check_delegation_endpoint "$k"
    done < <(bots)
    (( ${#keys[@]} == 0 )) && return 0
    [[ -n ${BOT_PREFIX:-} ]] || _bad "BOT_PREFIX is empty; bots are displayed as '<prefix> <Name>'"
    [[ -n ${TUNNEL_ZONE:-} ]] || _bad "bots need TUNNEL_ZONE for their hostnames"
    # One mailbox, several bots: every mail bot needs its own folder; INBOX
    # (the catch-all) can be read by one bot only.
    if (( emails > 0 )); then
        local -a folders=() inbox_readers=()
        local fk fold
        while IFS= read -r fk; do
            [[ -n $fk ]] || continue
            bot_has_channel "$fk" email || continue
            fold=$(bot_field "$fk" MAIL_FOLDER)
            for other in ${folders+"${folders[@]}"}; do [[ $other == "$fold" ]] && _bad "bots: mail folder '${fold}' is read by two bots"; done
            folders+=("$fold")
            [[ $fold == INBOX ]] && inbox_readers+=("$fk")
            [[ $fold == INBOX || -n $(bot_field "$fk" MAIL_ALIAS) ]] || _bad "bot ${fk}: a mail folder other than INBOX needs BOT_$(bot_upper "$fk")_MAIL_ALIAS (the address Exchange sorts into it)"
        done < <(bots)
        (( ${#inbox_readers[@]} <= 1 )) || _bad "bots: INBOX can be read by one bot only (${inbox_readers[*]}); give the others a MAIL_ALIAS"
    fi
    (( ${dashboards:-0} <= 1 )) || _bad "bots: BOT_<KEY>_DASHBOARD=true on one bot only"
    return 0
}

# A bot's own model, applied as LLM endpoint 1 for the duration of its pass.
# bot_llm_apply KEY saves the global endpoint settings; bot_llm_restore puts
# them back. Bots without BOT_<KEY>_LLM_MODEL keep the global endpoint.
bot_llm_apply() {
    local key=$1 model; model=$(bot_field "$key" LLM_MODEL)
    _BOT_LLM_SAVED=$(declare -p LLM_ENDPOINT_COUNT LLM_STRATEGY LLM_ENDPOINT_1_PROVIDER LLM_ENDPOINT_1_NAME \
                       LLM_ENDPOINT_1_BASE_URL LLM_ENDPOINT_1_MODEL LLM_ENDPOINT_1_TOKEN_VAR \
                       LLM_REASONING_FIELD LLM_CONTEXT_WINDOW 2>/dev/null)
    [[ -n $model ]] || return 0
    LLM_ENDPOINT_COUNT=1
    LLM_STRATEGY=single
    LLM_ENDPOINT_1_PROVIDER=$(bot_field "$key" LLM_PROVIDER)
    LLM_ENDPOINT_1_NAME=$(bot_field "$key" LLM_NAME)
    LLM_ENDPOINT_1_BASE_URL=$(bot_field "$key" LLM_BASE_URL)
    LLM_ENDPOINT_1_MODEL=$model
    LLM_ENDPOINT_1_TOKEN_VAR=$(bot_field "$key" LLM_TOKEN_VAR)
    LLM_REASONING_FIELD=$(bot_field "$key" LLM_REASONING_FIELD)
    LLM_CONTEXT_WINDOW=$(bot_field "$key" LLM_CONTEXT_WINDOW)
}

bot_llm_restore() {
    [[ -n ${_BOT_LLM_SAVED:-} ]] || return 0
    # declare -p prints `declare -- NAME=…`; evaluated inside a function that
    # would create LOCALS and leave the globals untouched — which put every bot
    # on the first bot's model once. -g restores the globals.
    eval "${_BOT_LLM_SAVED//declare -- /declare -g -- }"
    _BOT_LLM_SAVED=""
}

# session_reset_yaml SPEC -> the agent's session_reset block for none|daily@H|idle@M
session_reset_yaml() {
    case $1 in
        none)      printf 'session_reset:\n  mode: none\n' ;;
        daily@*)   printf 'session_reset:\n  mode: daily\n  at_hour: %s\n' "${1#daily@}" ;;
        idle@*)    printf 'session_reset:\n  mode: idle\n  idle_minutes: %s\n' "${1#idle@}" ;;
        *) return 1 ;;
    esac
}

_check_session_reset() {      # _check_session_reset NAME VALUE
    case $2 in
        none) ;;
        daily@*) [[ ${2#daily@} =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || _bad "$1: hour must be 0-23, got '${2#daily@}'" ;;
        idle@*)  [[ ${2#idle@} =~ ^[1-9][0-9]*$ ]] || _bad "$1: minutes must be a positive integer, got '${2#idle@}'" ;;
        *) _bad "$1 must be none, daily@HOUR or idle@MINUTES, got '$2'" ;;
    esac
}

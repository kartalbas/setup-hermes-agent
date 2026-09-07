#!/usr/bin/env bats
#
# Configuration loading, secret handling and validation (libs/20-config.sh).

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true          # validation skips the root requirement under a dry run
}

# --- secrets parsing --------------------------------------------------------
#
# The secrets file is parsed, never sourced. That is the whole point: a token is
# an arbitrary byte string, and sourcing one would execute whatever it contains.

@test "secrets_load reads plain assignments" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
TOKEN_A=abc123
TOKEN_B=def456
EOF
)
    secrets_load
    [ "$(secret_get TOKEN_A)" = "abc123" ]
    [ "$(secret_get TOKEN_B)" = "def456" ]
}

@test "secrets_load does not execute a value containing a command substitution" {
    local canary="${BATS_TEST_TMPDIR}/pwned"
    SECRETS_FILE=$(make_secrets_file <<EOF
EVIL=\$(touch ${canary})
EOF
)
    secrets_load
    [ ! -e "$canary" ]
    [ "$(secret_get EVIL)" = "\$(touch ${canary})" ]
}

@test "secrets_load does not execute backticks or a trailing command" {
    local canary="${BATS_TEST_TMPDIR}/pwned2"
    SECRETS_FILE=$(make_secrets_file <<EOF
EVIL=\`touch ${canary}\`
ALSO=value; touch ${canary}
EOF
)
    secrets_load
    [ ! -e "$canary" ]
}

@test "secrets_load keeps characters that would break a shell" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
WEIRD=a$b`c;d e|f&g
EOF
)
    secrets_load
    [ "$(secret_get WEIRD)" = 'a$b`c;d e|f&g' ]
}

@test "secrets_load strips exactly one layer of quotes" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
DQ="quoted"
SQ='single'
NESTED=""double""
EOF
)
    secrets_load
    [ "$(secret_get DQ)" = "quoted" ]
    [ "$(secret_get SQ)" = "single" ]
    [ "$(secret_get NESTED)" = '"double"' ]
}

@test "secrets_load ignores comments and blank lines" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
# a comment
   # an indented comment

REAL=value
EOF
)
    secrets_load
    [ "$(secret_get REAL)" = "value" ]
}

@test "secrets_load accepts an export prefix" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
export EXPORTED=value
EOF
)
    secrets_load
    [ "$(secret_get EXPORTED)" = "value" ]
}

@test "secrets_load refuses a file readable by others" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
TOKEN=value
EOF
)
    chmod 0644 "$SECRETS_FILE"
    bats_run secrets_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"0600"* ]]
}

@test "secrets_load rejects a line that is not an assignment" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
this is not an assignment
EOF
)
    bats_run secrets_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEY=value"* ]]
}

@test "secret_has distinguishes absent from empty" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
EMPTY=
EOF
)
    secrets_load
    bats_run secret_has EMPTY
    [ "$status" -eq 0 ]
    bats_run secret_has MISSING
    [ "$status" -ne 0 ]
}

@test "secret_require names the setting that needed the missing secret" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
PRESENT=value
EOF
)
    secrets_load
    bats_run secret_require ABSENT "the telegram channel"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ABSENT"* ]]
    [[ "$output" == *"telegram"* ]]
}

@test "loaded secrets are registered for redaction" {
    SECRETS_FILE=$(make_secrets_file <<'EOF'
TOKEN=super-secret-value
EOF
)
    secrets_load
    bats_run log_redact "using super-secret-value here"
    [ "$output" = "using <redacted> here" ]
}

# --- config file loading ----------------------------------------------------

@test "config_load refuses a config writable by group or others" {
    local cfg="${BATS_TEST_TMPDIR}/loose.conf"
    printf 'TIMEZONE="Europe/Berlin"\n' >"$cfg"
    chmod 0664 "$cfg"
    bats_run config_load "$cfg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"writable by group or others"* ]]
}

@test "config_load accepts a properly owned config" {
    local cfg="${BATS_TEST_TMPDIR}/ok.conf"
    printf 'TIMEZONE="Europe/Berlin"\n' >"$cfg"
    chmod 0644 "$cfg"
    config_load "$cfg"
    [ "$TIMEZONE" = "Europe/Berlin" ]
}

# No fallbacks: a run that proceeds without its configuration applies built-in
# defaults, reports success, and leaves the operator believing their settings
# took effect.
@test "config_load refuses a file that is not there" {
    bats_run config_load "${BATS_TEST_TMPDIR}/absent.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no configuration"* ]]
}

# --- precedence -------------------------------------------------------------
#
# Documented order: flag > environment > config file > built-in default.

@test "config_defaults fills unset values" {
    unset TIMEZONE
    config_defaults
    [ "$TIMEZONE" = "Etc/UTC" ]
}

@test "config_defaults does not overwrite a value already set" {
    TIMEZONE="Europe/Zurich"
    config_defaults
    [ "$TIMEZONE" = "Europe/Zurich" ]
}

# --- validation -------------------------------------------------------------
#
# Every problem is reported in one pass, by name, before anything is touched.

_valid_minimal_config() {
    # Normally supplied by config/bootstrap.conf, which the entry point loads
    # first; the unit tests source the libraries directly, so it is set here.
    BOOTSTRAP_USER="agent"
    config_defaults
    HERMES_REF="v1.2.3"
    SECRETS_FILE=$(make_secrets_file <<'EOF'
LLM_TOKEN=abc123def456
EOF
)
    secrets_load
    LLM_ENDPOINT_COUNT=1
    LLM_ENDPOINT_1_PROVIDER="custom"
    LLM_ENDPOINT_1_BASE_URL="https://llm.example.com/v1"
    LLM_ENDPOINT_1_MODEL="a-model"
    LLM_ENDPOINT_1_TOKEN_VAR="LLM_TOKEN"
    BACKUP_MANAGE=false
    DASHBOARD_ENABLED=false
    TUNNEL_MODE="none"
}

@test "a minimal configuration validates" {
    _valid_minimal_config
    bats_run config_validate
    [ "$status" -eq 0 ]
}

@test "validation rejects an illegal enum value and names the alternatives" {
    _valid_minimal_config
    SERVICE_SCOPE="bogus"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SERVICE_SCOPE"* ]]
    [[ "$output" == *"system"* ]]
}

@test "validation reports every problem in one pass" {
    _valid_minimal_config
    SERVICE_SCOPE="bogus"
    LLM_STRATEGY="parallel"
    HERMES_REF=""
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SERVICE_SCOPE"* ]]
    [[ "$output" == *"LLM_STRATEGY"* ]]
    [[ "$output" == *"HERMES_REF"* ]]
}

@test "validation requires a pinned revision" {
    _valid_minimal_config
    HERMES_REF=""
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"HERMES_REF"* ]]
}

@test "a custom endpoint must carry a base_url" {
    _valid_minimal_config
    LLM_ENDPOINT_1_BASE_URL=""
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"BASE_URL"* ]]
}

@test "a hosted provider must NOT carry a base_url" {
    _valid_minimal_config
    LLM_ENDPOINT_1_PROVIDER="anthropic"
    LLM_ENDPOINT_1_BASE_URL="https://llm.example.com/v1"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"not custom"* ]]
}

@test "a hosted provider without a base_url is accepted" {
    _valid_minimal_config
    LLM_ENDPOINT_1_PROVIDER="anthropic"
    LLM_ENDPOINT_1_BASE_URL=""
    bats_run config_validate
    [ "$status" -eq 0 ]
}

@test "plain http is refused except on loopback" {
    _valid_minimal_config
    LLM_ENDPOINT_1_BASE_URL="http://llm.example.com/v1"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"https"* ]]

    LLM_ENDPOINT_1_BASE_URL="http://127.0.0.1:8000/v1"
    bats_run config_validate
    [ "$status" -eq 0 ]
}

@test "failover needs more than one endpoint" {
    _valid_minimal_config
    LLM_STRATEGY="failover"
    LLM_ENDPOINT_COUNT=1
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"two endpoints"* ]]
}

@test "a custom endpoint naming an absent secret is rejected" {
    _valid_minimal_config
    LLM_ENDPOINT_1_TOKEN_VAR="NOT_IN_FILE"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT_IN_FILE"* ]]
}

@test "a published dashboard requires a password" {
    _valid_minimal_config
    DASHBOARD_ENABLED=true
    DASHBOARD_PROXY=true
    DASHBOARD_PROXY_BIND="192.0.2.5"   # RFC 5737 documentation range
    DASHBOARD_PROXY_PASSWORD_VAR="NO_SUCH_SECRET"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"NO_SUCH_SECRET"* ]]
}

@test "a dashboard bound to every interface is refused" {
    _valid_minimal_config
    DASHBOARD_ENABLED=true
    DASHBOARD_PROXY=true
    DASHBOARD_PROXY_BIND="0.0.0.0"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"every interface"* ]]
}

@test "a tunnel hostname outside its zone is refused" {
    _valid_minimal_config
    TUNNEL_MODE="assisted"
    TUNNEL_NAME="t"
    TUNNEL_HOSTNAME="agent.example.com"
    TUNNEL_ZONE="other.example.net"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"not inside"* ]]
}

# --- endpoint and provider helpers ------------------------------------------

@test "endpoint_field reads the numbered variables" {
    LLM_ENDPOINT_3_MODEL="claude-opus-4"
    bats_run endpoint_field 3 MODEL
    [ "$output" = "claude-opus-4" ]
}

@test "endpoint_field returns empty for an unset slot" {
    bats_run endpoint_field 9 MODEL
    [ "$output" = "" ]
}

@test "each hosted provider maps to the key variable it expects" {
    bats_run _provider_key_var anthropic
    [ "$output" = "ANTHROPIC_API_KEY" ]
    bats_run _provider_key_var google
    [ "$output" = "GOOGLE_API_KEY" ]
    bats_run _provider_key_var kimi-coding
    [ "$output" = "KIMI_API_KEY" ]
    bats_run _provider_key_var zai
    [ "$output" = "GLM_API_KEY" ]
}

@test "an unknown provider has no key variable" {
    bats_run _provider_key_var nonesuch
    [ "$status" -ne 0 ]
}

# --- channel reporting ------------------------------------------------------

@test "channels_enabled_list joins with spaces despite a restrictive IFS" {
    IFS=$'\n\t'
    CHANNEL_TELEGRAM_ENABLED=true
    CHANNEL_EMAIL_ENABLED=true
    CHANNEL_WHATSAPP_ENABLED=false
    CHANNEL_TEAMS_ENABLED=false
    bats_run channels_enabled_list
    [ "$output" = "telegram email" ]
}

@test "channels_enabled_list says none when nothing is enabled" {
    CHANNEL_TELEGRAM_ENABLED=false
    CHANNEL_EMAIL_ENABLED=false
    CHANNEL_WHATSAPP_ENABLED=false
    CHANNEL_TEAMS_ENABLED=false
    bats_run channels_enabled_list
    [ "$output" = "none" ]
}

# --- empty is not the same as present ---------------------------------------
#
# A half-filled credentials file is the normal state during setup. An empty
# value that passes validation and fails deep inside a run is the worst outcome:
# by then the host, the runtime and the service have already been changed.

@test "secret_nonempty rejects a present but empty value" {
    SECRETS_FILE=$(make_secrets_file <<'INNER'
EMPTY=
FILLED=value
INNER
)
    secrets_load
    bats_run secret_nonempty FILLED
    [ "$status" -eq 0 ]
    bats_run secret_nonempty EMPTY
    [ "$status" -ne 0 ]
    bats_run secret_nonempty ABSENT
    [ "$status" -ne 0 ]
}

@test "secret_require distinguishes empty from absent in its message" {
    SECRETS_FILE=$(make_secrets_file <<'INNER'
EMPTY=
INNER
)
    secrets_load
    bats_run secret_require EMPTY "the telegram channel"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]

    bats_run secret_require ABSENT "the telegram channel"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in"* ]]
}

@test "an endpoint token that is present but empty is rejected" {
    _valid_minimal_config
    SECRETS_FILE=$(make_secrets_file <<'INNER'
LLM_TOKEN=
INNER
)
    secrets_load
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "an enabled channel with no credentials fails validation, not the run" {
    _valid_minimal_config
    CHANNEL_TELEGRAM_ENABLED=true
    CHANNEL_TELEGRAM_TOKEN_VAR="TELEGRAM_BOT_TOKEN"
    CHANNEL_TELEGRAM_ALLOWLIST_VAR="TELEGRAM_ALLOWED_USERS"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"TELEGRAM_BOT_TOKEN"* ]]
    [[ "$output" == *"TELEGRAM_ALLOWED_USERS"* ]]
}

@test "an enabled webhook channel without a tunnel is rejected" {
    _valid_minimal_config
    CHANNEL_TEAMS_ENABLED=true
    TUNNEL_MODE="none"
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"webhooks"* ]]
}

# The account must not depend on who started the run.
@test "the service account comes from configuration, not the invoking user" {
    unset SERVICE_USER SERVICE_GROUP
    BOOTSTRAP_USER="from-config"
    config_defaults
    [ "$SERVICE_USER" = "from-config" ]
}

@test "a run with no configured account is refused" {
    _valid_minimal_config
    SERVICE_USER=""
    bats_run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"BOOTSTRAP_USER"* ]]
}

# A key the code reads must come from somewhere the operator can see: either a
# documented line in a tracked config file, or a default in 20-config.sh. This
# caught the templates describing a single mailbox after the code had moved to
# the PRIVATE/WORK pair, and the OAuth relay being undocumented while enabled.
@test "every key the code reads is either documented or defaulted" {
    local root="${BATS_TEST_DIRNAME}/../.."
    local undeclared
    undeclared=$(python3 - "$root" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])

sources = list((root/'libs').glob('*.sh')) + [root/'install.sh']
text = '\n'.join(f.read_text() for f in sources)

read = set(re.findall(r'\$\{([A-Z][A-Z0-9_]{2,})(?:[:#%/^,-]|\})', text))
read |= set(re.findall(r'"\$([A-Z][A-Z0-9_]{2,})"', text))

# Declared in a tracked config file, or given a default by config_defaults.
declared = set()
for name in ('config/hermes.conf.example', 'config/channels.conf.example',
             'config/install.conf', 'config/bootstrap.conf'):
    declared |= set(re.findall(r'^([A-Z][A-Z0-9_]*)=', (root/name).read_text(), re.M))
declared |= set(re.findall(r':\s*"\$\{([A-Z][A-Z0-9_]*):=', text))

# Assigned outright somewhere, so never unset at the point of use.
declared |= set(re.findall(r'^\s*(?:readonly\s+|export\s+|declare\s+-\w+\s+)?([A-Z][A-Z0-9_]{2,})=',
                           text, re.M))

# The shell's own, and the environment the run legitimately inherits.
shell = {'HOME','PATH','USER','SHELL','PWD','LANG','TERM','EUID','UID','IFS',
         'BASH_SOURCE','BASH_COMMAND','BASH_REMATCH','FUNCNAME','LINENO',
         'PIPESTATUS','OSTYPE','HOSTNAME','TMPDIR','NO_COLOR','DEBIAN_FRONTEND',
         'SUDO_USER','XDG_RUNTIME_DIR','GITHUB_TOKEN','NEEDRESTART_MODE'}

print('\n'.join(sorted(read - declared - shell)))
PY
)
    [ -z "$undeclared" ] || {
        printf 'read by the code but neither documented nor defaulted:\n%s\n' "$undeclared"
        false
    }
}

# An exported-but-empty HERMES_HOME overrides the vendor's own default with
# nothing, so the generated backup script must never receive one.
@test "HERMES_HOME is derived from the account home when not configured" {
    _valid_minimal_config
    unset HERMES_HOME
    BOOTSTRAP_USER="svc"
    BOOTSTRAP_HOME=""
    unset SERVICE_USER
    config_defaults
    [ "$HERMES_HOME" = "/home/svc/.hermes" ]
}

@test "an explicit HERMES_HOME wins over the derivation" {
    _valid_minimal_config
    HERMES_HOME="/srv/agent"
    BOOTSTRAP_USER="svc"
    config_defaults
    [ "$HERMES_HOME" = "/srv/agent" ]
}

@test "HERMES_HOME follows a relocated account home" {
    _valid_minimal_config
    unset HERMES_HOME SERVICE_USER
    BOOTSTRAP_USER="svc"
    BOOTSTRAP_HOME="/opt/svc"
    config_defaults
    [ "$HERMES_HOME" = "/opt/svc/.hermes" ]
}

# emailproxy matches section names against ^(IMAP|POP|SMTP)-(\d+)$ and exits
# with "No server configuration(s) found" when there are none — a message that
# points at the account section rather than the missing one. The generator once
# wrote a decorative "[Server setup]" heading and no sections at all.
@test "the relay configuration declares server sections, not just an account" {
    local src="${BATS_TEST_DIRNAME}/../../libs/55-mailproxy.sh"
    grep -q 'IMAP-\${MAILPROXY_IMAP_PORT}' "$src"
    grep -q 'SMTP-\${MAILPROXY_SMTP_PORT}' "$src"
    grep -q 'server_address' "$src"
    grep -q 'server_port' "$src"
    # A section named anything else is ignored in silence.
    ! grep -q '^\[Server setup\]' "$src"
}

# The pinned agent connects with imaplib.IMAP4_SSL and offers no alternative —
# imap_security exists only on main, in no release. So the loopback hop to the
# relay is TLS as well, against a self-signed certificate for 127.0.0.1 that the
# provisioner puts in the system trust store. An earlier version of this test
# asserted "plain", which is what the unreleased branch allows and what the
# installed code cannot do.
@test "going through the relay still uses TLS on the loopback hop" {
    _valid_minimal_config
    MAILPROXY_ENABLED=true
    MAILPROXY_LISTEN="127.0.0.1"
    MAILPROXY_IMAP_PORT=1993
    MAILPROXY_SMTP_PORT=1587
    CHANNEL_EMAIL_ACCOUNT="work"
    CHANNEL_EMAIL_WORK_ADDRESS="agent@example.com"
    CHANNEL_EMAIL_WORK_IMAP_HOST="outlook.example.com"
    CHANNEL_EMAIL_WORK_SMTP_HOST="smtp.example.com"
    CHANNEL_EMAIL_WORK_PASSWORD_VAR="EMAIL_WORK_PASSWORD"
    CHANNEL_EMAIL_IMAP_SECURITY="tls"
    CHANNEL_EMAIL_SMTP_SECURITY="starttls"
    _email_resolve
    [ "$EMAIL_IMAP_RESOLVED" = "127.0.0.1" ]
    [ "$EMAIL_IMAP_PORT_RESOLVED" = "1993" ]
    [ "$EMAIL_IMAP_SECURITY_RESOLVED" = "tls" ]
    [ "$EMAIL_SMTP_SECURITY_RESOLVED" = "starttls" ]
}

# The certificate is what makes that TLS hop possible; without it in the
# generated relay configuration the agent meets a plaintext socket and reports
# "[SSL: WRONG_VERSION_NUMBER]" once a minute.
@test "the relay configuration carries a local certificate" {
    local src="${BATS_TEST_DIRNAME}/../../libs/55-mailproxy.sh"
    grep -q 'local_certificate_path' "$src"
    grep -q 'local_key_path' "$src"
    grep -q 'subjectAltName=IP:127.0.0.1' "$src"
    grep -q 'update-ca-certificates' "$src"
}

@test "without the relay the configured transport is kept" {
    _valid_minimal_config
    MAILPROXY_ENABLED=false
    CHANNEL_EMAIL_ACCOUNT="private"
    CHANNEL_EMAIL_PRIVATE_ADDRESS="agent@example.com"
    CHANNEL_EMAIL_PRIVATE_IMAP_HOST="imap.example.com"
    CHANNEL_EMAIL_PRIVATE_SMTP_HOST="smtp.example.com"
    CHANNEL_EMAIL_PRIVATE_PASSWORD_VAR="EMAIL_PRIVATE_PASSWORD"
    CHANNEL_EMAIL_IMAP_SECURITY="tls"
    CHANNEL_EMAIL_SMTP_SECURITY="starttls"
    _email_resolve
    [ "$EMAIL_IMAP_SECURITY_RESOLVED" = "tls" ]
    [ "$EMAIL_SMTP_SECURITY_RESOLVED" = "starttls" ]
}

@test "a derived default follows a value the config files set later" {
    # install.sh calls config_defaults before AND after config_load; the first
    # pass must not lock in a value the files have not provided yet.
    unset ASSISTANT_VENV ASSISTANT_STATE_DIR
    config_defaults
    [ "$ASSISTANT_VENV" = "/var/lib/hermes-assistant/venv" ]
    unset ASSISTANT_VENV; ASSISTANT_STATE_DIR=/srv/assistant
    config_defaults
    [ "$ASSISTANT_VENV" = "/srv/assistant/venv" ]
}

@test "teams toolset and sender authentication default to the safe values" {
    unset CHANNEL_TEAMS_TOOLSET CHANNEL_EMAIL_REQUIRE_AUTHENTICATED_SENDER
    config_defaults
    [ "$CHANNEL_TEAMS_TOOLSET" = "hermes-telegram" ]
    [ "$CHANNEL_EMAIL_REQUIRE_AUTHENTICATED_SENDER" = "true" ]
}

@test "the IMAP probe retries a transient failure and keeps a credential rejection final" {
    _EMAIL_PROBE_RETRY_DELAY=0
    EMAIL_ACCOUNT_LABEL=work EMAIL_IMAP_RESOLVED=127.0.0.1 EMAIL_IMAP_PORT_RESOLVED=1993
    DRY_RUN=false
    _email_probe_once() { _probe_calls=$((_probe_calls + 1)); (( _probe_calls < 3 )) && return 3; return 0; }
    _probe_calls=0
    _email_probe secret
    [ "$_probe_calls" -eq 3 ]
    _email_probe_once() { _probe_calls=$((_probe_calls + 1)); return 2; }
    _probe_calls=0
    _email_via_relay() { return 1; }
    bats_run _email_probe secret
    [ "$status" -ne 0 ]
    [[ $output != *transient* ]]      # a rejected credential is final: no retry
}

@test "the site hostname follows the zone the config files set later" {
    unset SITE_HOSTNAME TUNNEL_ZONE
    config_defaults
    [ -z "$SITE_HOSTNAME" ]
    TUNNEL_ZONE=example.com
    config_defaults
    [ "$SITE_HOSTNAME" = "assistant.example.com" ]
}

@test "every key in the operator's real config files has a documented counterpart in the examples" {
    local real example missing
    for real in hermes channels secrets; do
        [ -f "$REPO_ROOT/config/$real.conf" ] || skip "no real $real.conf on this host"
        example="$REPO_ROOT/config/$real.conf.example"
        missing=$(LC_ALL=C comm -23 <(grep -oE '^[A-Z_0-9]+=' "$REPO_ROOT/config/$real.conf" | LC_ALL=C sort -u) \
                          <(grep -oE '^#? ?[A-Z_0-9]+=' "$example" | sed 's/^#\{0,1\} \{0,1\}//' | LC_ALL=C sort -u))
        [ -z "$missing" ] || { echo "missing in $real.conf.example: $missing"; false; }
    done
}

@test "yaml_list_ensure adds missing entries once and keeps what the agent wrote itself" {
    tmp=$(mktemp -d); printf 'command_allowlist:\n- execute_code\nother: 1\n' >"${tmp}/config.yaml"
    yaml_config_path() { printf '%s/config.yaml' "$tmp"; }
    DRY_RUN=false
    yaml_list_ensure command_allowlist "script execution via -e/-c flag" "execute_code"
    bats_run yaml_list_ensure command_allowlist "script execution via -e/-c flag"; [ "$status" -eq 3 ]
    python3 -c "
import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); assert c['command_allowlist']==['execute_code','script execution via -e/-c flag'], c; assert c['other']==1" "${tmp}/config.yaml"
    rm -rf "$tmp"
}

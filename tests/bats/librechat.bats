#!/usr/bin/env bats
#
# LibreChat in front of the bots with the `web` channel (ADR 0029): off unless
# asked for, validated against what it needs, loopback only, one picker entry
# per web bot, every window its own Hermes session, sign-in through Entra for
# one group, and nothing of it touching Teams, mail or cron.

setup() {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT
    TUNNEL_ZONE=example.com
    BOTS="secretary search tasks"
    BOT_PREFIX="Acme" BOT_SERVICE_PREFIX="acme"
    BOT_SECRETARY_CHANNELS="teams email web"
    BOT_TASKS_CHANNELS="teams web"
    config_defaults
}

secrets() {                       # a secrets file holding everything the module reads
    SECRETS_FILE=$(make_secrets_file <<'EOF'
AZURE_TENANT_ID=00000000-1111-2222-3333-444444444444
LIBRECHAT_CLIENT_ID=app-id-0000
LIBRECHAT_CLIENT_SECRET=client-secret-value
LIBRECHAT_GROUP_ID=group-id-1111
LIBRECHAT_CREDS_KEY=0000000000000000000000000000000000000000000000000000000000000000
LIBRECHAT_CREDS_IV=00000000000000000000000000000000
LIBRECHAT_JWT_SECRET=jwt-secret-value
LIBRECHAT_JWT_REFRESH_SECRET=jwt-refresh-value
LIBRECHAT_OPENID_SESSION_SECRET=session-secret-value
LIBRECHAT_MEILI_MASTER_KEY=meili-master-value
LIBRECHAT_MONGO_PASSWORD=mongo-password-value
HERMES_WEB_SECRETARY_KEY=secretary-web-key-0123456789
HERMES_WEB_TASKS_KEY=tasks-web-key-0123456789
EOF
)
    secrets_load
}

@test "off unless asked for, and the host is derived from the tunnel's zone" {
    [ "$LIBRECHAT_ENABLED" = false ]
    [ "$LIBRECHAT_HOSTNAME" = chat.example.com ]
    [ "$(librechat_title)" = "Acme Chat" ]
    [ "$(librechat_group)" = "acme-bots" ]
    [ "$(librechat_redirect_uri)" = "https://chat.example.com/oauth/openid/callback" ]
    LIBRECHAT_TITLE="Team Chat" LIBRECHAT_ENTRA_GROUP="chat-users"
    [ "$(librechat_title)" = "Team Chat" ] && [ "$(librechat_group)" = "chat-users" ]
}

@test "web is a channel like teams and email, with a loopback port and a key of its own" {
    [ "$(web_bots | tr '\n' ' ')" = "secretary tasks " ]
    [ "$(bot_field secretary WEB_PORT)" = 8642 ]
    [ "$(bot_field tasks WEB_PORT)" = 8644 ]
    [ "$(bot_field tasks WEB_KEY_VAR)" = HERMES_WEB_TASKS_KEY ]
    _invalid=(); _bots_validate
    [ "${#_invalid[@]}" -eq 0 ] || { printf '%s\n' "${_invalid[@]}"; false; }
    BOT_SEARCH_CHANNELS="teams chat"
    _invalid=(); _bots_validate
    [[ "${_invalid[*]}" == *"unknown channel 'chat' (teams, email, web)"* ]]
}

@test "a web port that collides with another bot's port is refused" {
    BOT_TASKS_WEB_PORT=3978                                    # the secretary's Teams webhook port
    _invalid=(); _bots_validate
    [[ "${_invalid[*]}" == *"port 3978 is used twice"* ]]
}

@test "enabled, it needs the tunnel, Entra, the engine and at least one web bot" {
    LIBRECHAT_ENABLED=true TUNNEL_MODE=api AZURE_MANAGE=true DOCKER_MANAGE=true
    _invalid=(); _validate_librechat
    [ "${#_invalid[@]}" -eq 0 ] || { printf '%s\n' "${_invalid[@]}"; false; }

    TUNNEL_MODE=none; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"TUNNEL_MODE"* ]]; TUNNEL_MODE=api
    AZURE_MANAGE=false; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"AZURE_MANAGE=true"* ]]; AZURE_MANAGE=true
    DOCKER_MANAGE=false; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"DOCKER_MANAGE=true"* ]]; DOCKER_MANAGE=true
    BOT_SECRETARY_CHANNELS="teams" BOT_TASKS_CHANNELS="teams"; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"no bot has the web channel"* ]]
    BOT_SECRETARY_CHANNELS="teams web"
    LIBRECHAT_HOSTNAME=chat.other.org; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"not in the tunnel's zone"* ]]; LIBRECHAT_HOSTNAME=chat.example.com
    LIBRECHAT_ENTRA_MEMBERS="someone"; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"'someone' is not an address"* ]]
    LIBRECHAT_ENABLED=false; _invalid=(); _validate_librechat
    [ "${#_invalid[@]}" -eq 0 ]
}

@test "librechat.yaml: one picker entry per web bot, each window its own Hermes session, LibreChat's tools off" {
    out=$(librechat_config_text)
    python3 - <<PY
import yaml
c = yaml.safe_load(r'''$out''')
assert c["version"] == "1.3.13"
eps = c["endpoints"]["custom"]
assert [e["name"] for e in eps] == ["Secretary", "Tasks"], eps          # web bots only, not search
sec = eps[0]
assert sec["baseURL"] == "http://127.0.0.1:8642/v1"
assert sec["apiKey"] == "\${HERMES_WEB_SECRETARY_KEY}"                  # a reference, never the key
assert sec["models"] == {"default": ["secretary"], "fetch": False}     # the bot's own model name
assert sec["headers"] == {"X-Hermes-Session-Id": "{{LIBRECHAT_BODY_CONVERSATIONID}}"}
assert sec["titleConvo"] is False and sec["summarize"] is False        # no extra agent runs per chat
specs = c["modelSpecs"]
assert specs["enforce"] is True
assert [s["preset"] for s in specs["list"]] == [{"endpoint": "Secretary", "model": "secretary", "resendFiles": False},
                                                {"endpoint": "Tasks", "model": "tasks", "resendFiles": False}]
assert [s["default"] for s in specs["list"]] == [True, False]
assert all(s["description"] for s in specs["list"]), "the role's summary line describes the entry"
ui = c["interface"]
for off in ("modelSelect", "presets", "agents", "memories", "webSearch", "runCode", "fileSearch", "prompts"):
    assert ui[off] is False, off
assert c["registration"]["socialLogins"] == ["openid"]
PY
}

@test "librechat.yaml: photos and documents go to the bots, with the window the bot really has" {
    BOT_SECRETARY_LLM_CONTEXT_WINDOW=512000 LLM_CONTEXT_WINDOW=400000
    out=$(librechat_config_text)
    python3 - <<PY
import re, yaml
c = yaml.safe_load(r'''$out''')
eps = {e["name"]: e for e in c["endpoints"]["custom"]}
assert eps["Secretary"]["tokenConfig"] == {"secretary": {"prompt": 0, "completion": 0, "context": 512000}}
assert eps["Tasks"]["tokenConfig"]["tasks"]["context"] == 400000           # the global window
assert all(s["preset"]["resendFiles"] is False for s in c["modelSpecs"]["list"])
fc = c["fileConfig"]
assert set(fc["endpoints"]) == {"Secretary", "Tasks"}
lim = fc["endpoints"]["Secretary"]
assert lim["fileSizeLimit"] == 25 and lim["fileLimit"] == 10
for mime in ("image/jpeg", "image/heic", "application/pdf", "text/plain",
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document"):
    assert any(re.match(p, mime) for p in lim["supportedMimeTypes"]), mime
assert not any(re.match(p, "application/x-sh") for p in lim["supportedMimeTypes"])
assert fc["clientImageResize"]["enabled"] is True and fc["clientImageResize"]["maxWidth"] == 3072
PY
    LLM_CONTEXT_WINDOW=0 BOT_SECRETARY_LLM_CONTEXT_WINDOW=0
    [[ $(librechat_config_text) != *"tokenConfig"* ]]              # unknown: LibreChat's own guess, not a made-up number
}

@test "compose: everything on loopback, nothing published, images pinned, the database behind a password" {
    out=$(librechat_compose_text)
    [[ $out != *"ports:"* ]]
    [ "$(grep -c 'network_mode: host' <<<"$out")" -eq 3 ]
    [[ $out == *"--bind_ip 127.0.0.1 --port 27018"* ]]
    [[ $out == *"MEILI_HTTP_ADDR: 127.0.0.1:7701"* ]]
    [[ $out == *"MONGO_INITDB_ROOT_PASSWORD: \${LIBRECHAT_MONGO_PASSWORD}"* ]]
    [[ $out == *"image: ghcr.io/danny-avila/librechat:v0.8.7"* ]]
    [[ $out != *":latest"* ]]
    [[ $out == *"./librechat.yaml:/app/librechat.yaml:ro"* ]]
    python3 -c 'import sys, yaml; d = yaml.safe_load(sys.stdin); assert set(d["services"]) == {"mongodb", "meilisearch", "api"}' <<<"$out"
}

@test ".env: loopback, Entra only, the group checked again, the bots' keys for the references" {
    secrets
    out=$(librechat_env_text)
    [[ $out == *$'\nHOST=127.0.0.1\n'* ]]
    [[ $out == *$'\nPORT=3080\n'* ]]
    [[ $out == *"DOMAIN_CLIENT=https://chat.example.com"* ]]
    [[ $out == *"ALLOW_EMAIL_LOGIN=false"* && $out == *"ALLOW_REGISTRATION=false"* ]]
    [[ $out == *"ALLOW_SOCIAL_LOGIN=true"* ]]
    [[ $out == *"OPENID_ISSUER=https://login.microsoftonline.com/00000000-1111-2222-3333-444444444444/v2.0"* ]]
    [[ $out == *"OPENID_CLIENT_ID=app-id-0000"* && $out == *"OPENID_CLIENT_SECRET=client-secret-value"* ]]
    [[ $out == *"OPENID_REQUIRED_ROLE=group-id-1111"* ]]
    [[ $out == *"OPENID_REQUIRED_ROLE_PARAMETER_PATH=groups"* ]]
    [[ $out == *"MONGO_URI=mongodb://librechat:mongo-password-value@127.0.0.1:27018/LibreChat?authSource=admin"* ]]
    [[ $out == *"HERMES_WEB_SECRETARY_KEY=secretary-web-key-0123456789"* ]]
    [[ $out == *"HERMES_WEB_TASKS_KEY=tasks-web-key-0123456789"* ]]
    [[ $out != *"HERMES_WEB_SEARCH_KEY"* ]]
    [[ $out == *'APP_TITLE="Acme Chat"'* ]]
}

@test "the unit brings the three containers up and down with compose, after the engine" {
    out=$(librechat_unit_text)
    [[ $out == *"Requires=docker.service"* ]]
    [[ $out == *"Type=oneshot"* && $out == *"RemainAfterExit=yes"* ]]
    [[ $out == *"WorkingDirectory=/opt/hermes-librechat"* ]]
    [[ $out == *"compose up --detach --remove-orphans"* && $out == *"compose down"* ]]
    [ "$(librechat_unit_name)" = "$(shared_service_name)-librechat" ]
}

@test "the tunnel publishes the chat host only when LibreChat is on" {
    TUNNEL_INGRESS_PATH=/api/messages
    ! tunnel_hostnames | grep -qx chat.example.com
    ! tunnel_ingress_rules | grep -q chat.example.com
    LIBRECHAT_ENABLED=true
    tunnel_hostnames | grep -qx chat.example.com
    tunnel_ingress_rules | grep -qF '{"hostname":"chat.example.com","service":"http://127.0.0.1:3080"}'
    [ "$(tunnel_ingress_rules | tail -1)" = '{"service":"http_status:404"}' ]
}

@test "the web channel starts the bot's API server with a minted key and the bot's toolset, and removes it again" {
    secrets
    local home="${BATS_TEST_TMPDIR}/profile"; mkdir -p "$home"
    HERMES_CONFIG_HOME=$home DRY_RUN=false SERVICE_USER="" BOT_KEY=tasks
    BOT_TOOLSET="memory session_search clarify cronjob"
    local merged="${BATS_TEST_TMPDIR}/merged.yaml"
    yaml_merge() { cat >>"$merged"; }
    _toolset_check() { :; }
    CHANNEL_WEB_ENABLED=true CHANNEL_WEB_PORT=8647 CHANNEL_WEB_KEY_VAR=HERMES_WEB_TASKS_KEY
    _channel_web
    grep -qx 'API_SERVER_KEY=tasks-web-key-0123456789' "$home/.env"
    grep -qx 'API_SERVER_HOST=127.0.0.1' "$home/.env"
    grep -qx 'API_SERVER_PORT=8647' "$home/.env"
    grep -qx 'API_SERVER_MODEL_NAME=tasks' "$home/.env"
    grep -q '  api_server:' "$merged" && grep -q '    - memory' "$merged"

    # a key the secrets file lacks is minted and written back, not invented per run
    CHANNEL_WEB_KEY_VAR=HERMES_WEB_NEW_KEY
    _channel_web
    secret_nonempty HERMES_WEB_NEW_KEY
    [ "$(secret_get HERMES_WEB_NEW_KEY | wc -c)" -ge 33 ]
    grep -qx "API_SERVER_KEY=$(secret_get HERMES_WEB_NEW_KEY)" "$home/.env"

    # switched off: the key goes, and with it the listener
    printf 'OTHER=1\n' >>"$home/.env"
    CHANNEL_WEB_ENABLED=false
    _channel_web
    ! grep -q '^API_SERVER_' "$home/.env"
    grep -qx 'OTHER=1' "$home/.env"
}

@test "the engine is installed for LibreChat even without a docker terminal" {
    grep -qF 'if [[ $TERMINAL_BACKEND != docker ]] && ! is_true "${LIBRECHAT_ENABLED:-false}"; then' "$REPO_ROOT/libs/50-docker.sh"
    grep -qF '[[ $TERMINAL_BACKEND == docker ]] || return 0' "$REPO_ROOT/libs/50-docker.sh"
}

@test "the module runs after what it needs and is mapped for the ops applier" {
    local order; order=$(grep -oE '^readonly MODULES=\(.*\)' "$REPO_ROOT/install.sh")
    [[ $order == *"azure"*"docker"*"channels"*"librechat"* ]]
    grep -qE '^ +libs/88-\*\) +add librechat ;;' "$REPO_ROOT/bot/ops/opsctl"
    grep -qx '    librechat_uninstall' "$REPO_ROOT/libs/99-uninstall.sh"
}

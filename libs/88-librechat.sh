# shellcheck shell=bash
#
# LibreChat: a web chat in front of the bots that have the `web` channel
# (ADR 0029).
#
# Three containers on the host's loopback — LibreChat, MongoDB for its
# conversations, Meilisearch for searching them — brought up by one systemd
# unit. Nothing is published: every service runs on the host network bound to
# 127.0.0.1, and the only way in from outside is the tunnel's hostname, where
# LibreChat asks for an Entra sign-in (the azure module makes the app, the
# group and the assignment).
#
# Each bot with the `web` channel is one entry in the picker: a custom endpoint
# on the bot's own API server (the channels module starts it). LibreChat's
# conversation id travels as the Hermes session id, so every window is a
# session of its own, with its whole tool history on the agent's side.
# LibreChat's own tools stay off — the bots are the brain, LibreChat is the
# window. Teams, mail and cron are untouched by any of this.

librechat_apply() {
    if ! is_true "${LIBRECHAT_ENABLED:-false}"; then
        log_skip "LibreChat disabled (LIBRECHAT_ENABLED=false)"
        return 0
    fi
    log_step "LibreChat"
    require_root "installing LibreChat"
    [[ $DRY_RUN == true ]] || have_cmd docker ||
        die "LibreChat runs in containers and there is no engine: run the docker module (DOCKER_MANAGE=true) first"

    local before=$CHANGE_COUNT
    _librechat_secrets
    _librechat_files
    _librechat_write_unit
    _librechat_images
    converge_unit "$(librechat_unit_name).service" "$before"
    _librechat_verify
}

librechat_unit_name() { printf '%s-librechat' "$(shared_service_name)"; }
librechat_project()   { printf 'hermes-librechat'; }

# ---------------------------------------------------------------------------
# Secrets. The run's own, minted once into the secrets file like the bridge
# token; LibreChat's Entra app (LIBRECHAT_CLIENT_*, LIBRECHAT_GROUP_ID) and the
# bots' API keys (HERMES_WEB_<KEY>_KEY) are written by the azure and channels
# modules, which run before this one.
# ---------------------------------------------------------------------------
_librechat_secret_ensure() {      # _librechat_secret_ensure VAR BYTES — hex, minted once
    local var=$1 bytes=$2
    secret_nonempty "$var" && return 0
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would mint ${var} and write it to ${SECRETS_FILE}"
        return 0
    fi
    local value; value=$(head -c "$bytes" /dev/urandom | od -An -vtx1 | tr -d ' \n')
    [[ ${#value} -eq $(( bytes * 2 )) ]] || die "could not mint ${var}"
    log_redact_register "$value"
    _secrets_append "$var" "$value"
    mark_changed; log_ok "${var} minted and written to the secrets file"
}

_librechat_secrets() {
    _librechat_secret_ensure LIBRECHAT_CREDS_KEY 32            # LibreChat wants exactly 32 bytes, hex
    _librechat_secret_ensure LIBRECHAT_CREDS_IV 16             # and exactly 16 here
    _librechat_secret_ensure LIBRECHAT_JWT_SECRET 32
    _librechat_secret_ensure LIBRECHAT_JWT_REFRESH_SECRET 32
    _librechat_secret_ensure LIBRECHAT_OPENID_SESSION_SECRET 32
    _librechat_secret_ensure LIBRECHAT_MEILI_MASTER_KEY 32
    _librechat_secret_ensure LIBRECHAT_MONGO_PASSWORD 24       # hex: nothing to escape in the URI
    [[ $DRY_RUN == true ]] && return 0
    local var
    for var in LIBRECHAT_CLIENT_ID LIBRECHAT_CLIENT_SECRET LIBRECHAT_GROUP_ID; do
        secret_nonempty "$var" || die "LibreChat has no ${var} yet: the azure module writes it (LIBRECHAT_ENABLED=true, then --only azure)"
    done
    local k
    while IFS= read -r k; do
        [[ -n $k ]] || continue
        secret_nonempty "$(bot_field "$k" WEB_KEY_VAR)" ||
            die "bot ${k} has no $(bot_field "$k" WEB_KEY_VAR) yet: the channels module mints it"
    done < <(web_bots)
}

# ---------------------------------------------------------------------------
# The three files. Rendered as text so the tests can read exactly what the
# host gets; only the .env holds secrets, and it is 0600.
# ---------------------------------------------------------------------------
librechat_compose_text() {
    cat <<EOF
# Managed by setup-hermes-agent (libs/88-librechat.sh), ADR 0029.
# Every service on the host network, bound to 127.0.0.1: nothing is published,
# and LibreChat reaches the bots' API servers on loopback. The tunnel is the
# only way in from outside.
name: $(librechat_project)
services:
  mongodb:
    image: ${LIBRECHAT_MONGO_IMAGE}
    network_mode: host
    restart: unless-stopped
    command: mongod --bind_ip 127.0.0.1 --port ${LIBRECHAT_MONGO_PORT} --wiredTigerCacheSizeGB 0.25
    environment:
      MONGO_INITDB_ROOT_USERNAME: librechat
      MONGO_INITDB_ROOT_PASSWORD: \${LIBRECHAT_MONGO_PASSWORD}
    volumes:
      - mongo:/data/db
  meilisearch:
    image: ${LIBRECHAT_MEILI_IMAGE}
    network_mode: host
    restart: unless-stopped
    environment:
      MEILI_HTTP_ADDR: 127.0.0.1:${LIBRECHAT_MEILI_PORT}
      MEILI_MASTER_KEY: \${MEILI_MASTER_KEY}
      MEILI_ENV: production
      MEILI_NO_ANALYTICS: "true"
    volumes:
      - meili:/meili_data
  api:
    image: ${LIBRECHAT_IMAGE}
    network_mode: host
    restart: unless-stopped
    depends_on: [mongodb, meilisearch]
    env_file: .env
    volumes:
      - ./librechat.yaml:/app/librechat.yaml:ro
      - uploads:/app/uploads
      - images:/app/client/public/images
# Named volumes, not bind mounts: LibreChat runs as the image's node user, and
# a named volume starts with the image's own directory and its owner. Its logs
# stay with the container: docker compose logs api, in the directory above.
volumes:
  mongo: {}
  meili: {}
  uploads: {}
  images: {}
EOF
}

librechat_env_text() {
    local mongo_pw tenant k
    mongo_pw=$(secret_get LIBRECHAT_MONGO_PASSWORD)
    tenant=$(secret_get "${AZURE_TENANT_ID_VAR:-AZURE_TENANT_ID}")
    cat <<EOF
# Managed by setup-hermes-agent (libs/88-librechat.sh), ADR 0029. Secrets: 0600, root.
HOST=127.0.0.1
PORT=${LIBRECHAT_PORT}
NODE_ENV=production
DOMAIN_CLIENT=$(librechat_url)
DOMAIN_SERVER=$(librechat_url)
TRUST_PROXY=1
NO_INDEX=true
APP_TITLE="$(librechat_title)"
CONFIG_PATH=/app/librechat.yaml
DEBUG_LOGGING=false
MONGO_URI=mongodb://librechat:${mongo_pw}@127.0.0.1:${LIBRECHAT_MONGO_PORT}/LibreChat?authSource=admin
LIBRECHAT_MONGO_PASSWORD=${mongo_pw}
SEARCH=true
MEILI_HOST=http://127.0.0.1:${LIBRECHAT_MEILI_PORT}
MEILI_MASTER_KEY=$(secret_get LIBRECHAT_MEILI_MASTER_KEY)
MEILI_NO_ANALYTICS=true
CREDS_KEY=$(secret_get LIBRECHAT_CREDS_KEY)
CREDS_IV=$(secret_get LIBRECHAT_CREDS_IV)
JWT_SECRET=$(secret_get LIBRECHAT_JWT_SECRET)
JWT_REFRESH_SECRET=$(secret_get LIBRECHAT_JWT_REFRESH_SECRET)
# Entra only: no local accounts, no registration form, the first sign-in of a
# group member creates the account.
ALLOW_EMAIL_LOGIN=false
ALLOW_REGISTRATION=false
ALLOW_PASSWORD_RESET=false
ALLOW_SOCIAL_LOGIN=true
ALLOW_SOCIAL_REGISTRATION=true
ALLOW_SHARED_LINKS=false
OPENID_CLIENT_ID=$(secret_get LIBRECHAT_CLIENT_ID)
OPENID_CLIENT_SECRET=$(secret_get LIBRECHAT_CLIENT_SECRET)
OPENID_ISSUER=https://login.microsoftonline.com/${tenant}/v2.0
OPENID_SESSION_SECRET=$(secret_get LIBRECHAT_OPENID_SESSION_SECRET)
OPENID_SCOPE="openid profile email"
OPENID_CALLBACK_URL=/oauth/openid/callback
OPENID_BUTTON_LABEL=Microsoft
OPENID_AUTO_REDIRECT=true
# The same group Entra admits, checked again from the ID token's groups claim.
OPENID_REQUIRED_ROLE=$(secret_get LIBRECHAT_GROUP_ID)
OPENID_REQUIRED_ROLE_TOKEN_KIND=id
OPENID_REQUIRED_ROLE_PARAMETER_PATH=groups
# The bots' API keys, referenced from librechat.yaml.
EOF
    while IFS= read -r k; do
        [[ -n $k ]] || continue
        printf '%s=%s\n' "$(bot_field "$k" WEB_KEY_VAR)" "$(secret_get "$(bot_field "$k" WEB_KEY_VAR)")"
    done < <(web_bots)
}

# librechat.yaml, built as JSON with jq and written out as YAML: every string
# is escaped by a serializer, not by hand. The bots' keys stay references
# (${HERMES_WEB_<KEY>_KEY}) that LibreChat resolves from its environment.
librechat_config_json() {
    local k first=true specs='[]' endpoints='[]' files='{}' name summary window
    while IFS= read -r k; do
        [[ -n $k ]] || continue
        name=$(bot_field "$k" NAME)
        summary=$(role_summary "$(bot_role_file "$k")" 2>/dev/null || true)
        # The window the bot itself works with (the agent compresses at half of
        # it), not LibreChat's guess for a model name it does not know (~32k).
        window=$(bot_field "$k" LLM_CONTEXT_WINDOW); [[ $window =~ ^[0-9]+$ ]] || window=0
        endpoints=$(jq -c --arg name "$name" --arg key "$k" --arg kv "\${$(bot_field "$k" WEB_KEY_VAR)}" \
                      --arg url "http://127.0.0.1:$(bot_field "$k" WEB_PORT)/v1" --argjson window "$window" '. + [{
            name: $name, apiKey: $kv, baseURL: $url,
            models: {default: [$key], fetch: false},
            titleConvo: false, summarize: false, modelDisplayLabel: $name,
            headers: {"X-Hermes-Session-Id": "{{LIBRECHAT_BODY_CONVERSATIONID}}"},
            dropParams: ["stop", "user", "frequency_penalty", "presence_penalty"]}
            + (if $window > 0 then {tokenConfig: {($key): {prompt: 0, completion: 0, context: $window}}} else {} end)]' <<<"$endpoints")
        # Photos (the phone's camera included) and documents go to the bot as
        # files (the agent's carried web-files patch caches them like a Teams
        # attachment); earlier ones are not sent again — the bot keeps them.
        specs=$(jq -c --arg name "$name" --arg key "$k" --arg d "$summary" --argjson def "$first" '. + [{
            name: $key, label: $name, description: $d, default: $def,
            preset: {endpoint: $name, model: $key, resendFiles: false}}]' <<<"$specs")
        files=$(jq -c --arg name "$name" '. + {($name): {fileLimit: 10, fileSizeLimit: 25, totalSizeLimit: 25,
            supportedMimeTypes: ["^image/.*$", "^application/pdf$", "^text/.*$", "^application/msword$",
                                 "^application/vnd\\.ms-excel$",
                                 "^application/vnd\\.openxmlformats-officedocument\\..*$"]}}' <<<"$files")
        first=false
    done < <(web_bots)
    jq -n --argjson endpoints "$endpoints" --argjson specs "$specs" --argjson files "$files" \
          --arg welcome "$LIBRECHAT_WELCOME" '{
        version: "1.3.13",
        cache: true,
        interface: {
            customWelcome: $welcome,
            modelSelect: false, parameters: false, presets: false, prompts: false, agents: false,
            bookmarks: true, memories: false, multiConvo: false, webSearch: false, runCode: false,
            fileSearch: false, fileCitations: false,
            peoplePicker: {users: false, groups: false, roles: false},
            marketplace: {use: false}},
        registration: {socialLogins: ["openid"]},
        # A phone photo is shrunk in the browser before it is sent: faster, and
        # 3072 px still keeps a scanned page legible.
        fileConfig: {endpoints: $files, serverFileSizeLimit: 25,
                     clientImageResize: {enabled: true, maxWidth: 3072, maxHeight: 3072, quality: 0.9}},
        endpoints: {custom: $endpoints},
        modelSpecs: {enforce: true, prioritize: true, list: $specs}}'
}

librechat_config_text() {
    local py
    py=$(_yaml_python) || die "no interpreter with PyYAML available to write librechat.yaml"
    printf '# Managed by setup-hermes-agent (libs/88-librechat.sh), ADR 0029.\n'
    librechat_config_json | "$py" -c 'import json, sys, yaml; yaml.safe_dump(json.load(sys.stdin), sys.stdout, sort_keys=False, allow_unicode=True, default_flow_style=False)'
}

_librechat_files() {
    ensure_dir "$LIBRECHAT_DIR" 0755
    write_file "${LIBRECHAT_DIR}/compose.yaml" 0644 <<<"$(librechat_compose_text)"
    write_file "${LIBRECHAT_DIR}/librechat.yaml" 0644 <<<"$(librechat_config_text)"
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write ${LIBRECHAT_DIR}/.env (0600) with LibreChat's secrets"
        return 0
    fi
    write_file "${LIBRECHAT_DIR}/.env" 0600 <<<"$(librechat_env_text)"
}

# ---------------------------------------------------------------------------
# The unit: compose up on start, down on stop. A restart recreates the
# containers, which is how a changed .env or librechat.yaml takes effect —
# LibreChat reads both only when it starts.
# ---------------------------------------------------------------------------
librechat_unit_text() {
    local docker; docker=$(command -v docker || printf /usr/bin/docker)
    cat <<EOF
# Managed by setup-hermes-agent.
[Unit]
Description=LibreChat, the web chat in front of the bots' web channel (ADR 0029)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${LIBRECHAT_DIR}
ExecStart=${docker} compose up --detach --remove-orphans
ExecStop=${docker} compose down
# The first start pulls about a gigabyte of images.
TimeoutStartSec=900
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
}

_librechat_write_unit() {
    write_file "/etc/systemd/system/$(librechat_unit_name).service" 0644 <<<"$(librechat_unit_text)"
    run systemctl daemon-reload
}

# Pulled here, not by the unit's first start: a gigabyte against a start
# timeout is a failure that reads as LibreChat being broken.
_librechat_images() {
    local image missing=false
    for image in "$LIBRECHAT_IMAGE" "$LIBRECHAT_MONGO_IMAGE" "$LIBRECHAT_MEILI_IMAGE"; do
        [[ $DRY_RUN != true ]] && docker image inspect "$image" >/dev/null 2>&1 && continue
        missing=true
    done
    if [[ $missing == false ]]; then
        log_skip "LibreChat images present"
        return 0
    fi
    log_info "pulling the LibreChat images (about a gigabyte the first time)"
    run docker compose --project-directory "$LIBRECHAT_DIR" pull --quiet ||
        die "could not pull the LibreChat images"
    mark_changed
}

_librechat_verify() {
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] would verify LibreChat and the bots' API servers"; return 0; }
    local url="http://127.0.0.1:${LIBRECHAT_PORT}/health" waited=0
    while (( waited < 180 )); do
        [[ $(http_status "$url") == 200 ]] && break
        sleep 3; waited=$(( waited + 3 ))
    done
    if [[ $(http_status "$url") != 200 ]]; then
        log_error "LibreChat did not answer within 180s; its last log lines:"
        docker compose --project-directory "$LIBRECHAT_DIR" logs --no-color --tail 30 api >&2 || true
        die "LibreChat failed to start"
    fi
    # LibreChat does not refuse an invalid librechat.yaml: it logs the error
    # and starts with its defaults, which would silently lose the bots.
    local logs
    logs=$(docker compose --project-directory "$LIBRECHAT_DIR" logs --no-color api 2>/dev/null || true)
    if grep -qiE "invalid custom config|custom config file.*(error|invalid)" <<<"$logs"; then
        grep -iE -A5 "invalid custom config" <<<"$logs" | head -20 >&2 || true
        die "LibreChat rejected librechat.yaml; the lines above say why"
    fi
    log_ok "LibreChat answering on 127.0.0.1:${LIBRECHAT_PORT} -> $(librechat_url)"
    local k port
    while IFS= read -r k; do
        [[ -n $k ]] || continue
        port=$(bot_field "$k" WEB_PORT)
        if [[ $(http_status "http://127.0.0.1:${port}/health") == 200 ]]; then
            log_ok "  $(bot_field "$k" NAME): the bot's API server on 127.0.0.1:${port}"
        else
            log_warn "  $(bot_field "$k" NAME): no API server on 127.0.0.1:${port} yet (restart $(bot_field "$k" SERVICE) or re-run the channels module)"
        fi
    done < <(web_bots)
}

# The containers and their unit go; the conversations stay in the volumes
# unless --purge, like the relay's state.
librechat_uninstall() {
    local unit; unit=$(librechat_unit_name)
    if have_cmd systemctl && systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "$unit"; then
        run systemctl disable --now "${unit}.service" || true
        run rm -f "/etc/systemd/system/${unit}.service"
        run systemctl daemon-reload
        mark_changed
    fi
    if [[ -f ${LIBRECHAT_DIR}/compose.yaml ]] && have_cmd docker; then
        if [[ ${DO_PURGE:-false} == true ]]; then
            run docker compose --project-directory "$LIBRECHAT_DIR" down --volumes || true
        else
            run docker compose --project-directory "$LIBRECHAT_DIR" down || true
            log_info "kept LibreChat's volumes (its conversations); use --purge to remove them"
        fi
    fi
    [[ -d $LIBRECHAT_DIR ]] && run rm -rf "$LIBRECHAT_DIR"
    return 0
}

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
    LIBRECHAT_APP_COLOR=green; _invalid=(); _validate_librechat
    [[ "${_invalid[*]}" == *"LIBRECHAT_APP_COLOR must be a colour"* ]]; LIBRECHAT_APP_COLOR="#10a37f"
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

# The app and the scanner: LibreChat is not rebuilt; its page is derived from
# the image, and its static directory gets a folder for each, all mounted.
@test "the app and the scanner ride on LibreChat's own page and files, the scanner with its switch" {
    out=$(librechat_compose_text)
    python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
v = d["services"]["api"]["volumes"]
for m in ("./index.html:/app/client/dist/index.html:ro", "./app:/app/client/dist/hermes-app:ro",
          "./scanner:/app/client/dist/hermes-scan:ro"):
    assert m in v, (m, v)
assert set(d["volumes"]) == {"mongo", "meili", "uploads", "images"}, d["volumes"]' <<<"$out"
    LIBRECHAT_SCANNER=false
    out=$(librechat_compose_text)
    [[ $out != *"hermes-scan"* && $out == *"index.html:/app/client"* && $out == *"hermes-app"* ]]
    python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin)' <<<"$out"
}

# LibreChat's page as the pinned image has it, as far as the app and the scanner touch it.
image_page() {
    cat <<'HTML'
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <meta name="theme-color" content="#171717" />
    <title>LibreChat</title>
    <link rel="icon" type="image/png" sizes="32x32" href="assets/favicon-32x32.png" />
    <link rel="icon" type="image/png" sizes="16x16" href="assets/favicon-16x16.png" />
    <link rel="apple-touch-icon" href="assets/apple-touch-icon-180x180.png" />
    <link rel="manifest" href="./manifest.webmanifest" crossorigin="use-credentials">
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
HTML
}

@test "LibreChat's page becomes the app: its name, its manifest and icons, the app's and the scanner's tags, each once" {
    LIBRECHAT_TITLE='Acme & Co "Chat"'
    out=$(librechat_page_html app123 scan456 true <<<"$(image_page)")
    [[ $out == *'<title>Acme &amp; Co &quot;Chat&quot;</title>'* ]]
    [[ $out == *'<meta name="application-name" content="Acme &amp; Co &quot;Chat&quot;" />'* ]]
    [[ $out == *'<meta name="apple-mobile-web-app-title" content="Acme &amp; Co &quot;Chat&quot;" />'* ]]
    [[ $out == *'<link rel="manifest" href="./hermes-app/manifest.webmanifest?v=app123" crossorigin="use-credentials">'* ]]
    [[ $out == *'href="hermes-app/apple-touch-icon.png?v=app123"'* && $out == *'href="hermes-app/favicon-16.png?v=app123"'* ]]
    [[ $out == *'<script defer src="./hermes-app/app.js?v=app123"></script><script defer src="./hermes-scan/scan.js?v=scan456"></script></body>'* ]]
    [[ $out != *"assets/apple-touch-icon"* && $out != *'href="./manifest.webmanifest"'* ]]
    # no scanner, no icons of its own: LibreChat's icons stay, and no scanner tag
    out=$(librechat_page_html app123 "" false <<<"$(image_page)")
    [[ $out == *'href="assets/apple-touch-icon-180x180.png"'* && $out != *"hermes-scan"* ]]
    [[ $out == *'<script defer src="./hermes-app/app.js?v=app123"></script></body>'* ]]
    # never twice: the page must come from the image
    bats_run librechat_page_html app123 "" false <<<"$out"
    [ "$status" -ne 0 ]
    # a page that changed stops the run; nothing is guessed
    bats_run librechat_page_html app123 "" false <<<"<html><head><title>Other</title></head><body></body></html>"
    [ "$status" -ne 0 ] && [[ $output == *"review the page"* ]]
}

@test "the run derives the page from the image, and keeps the old one rather than write one it could not derive" {
    IFS=$'\n\t'                                          # as in install.sh
    LIBRECHAT_DIR=$(mktemp -d); DRY_RUN=false
    docker() { image_page; }
    _librechat_page
    grep -q "hermes-scan/scan.js?v=$(librechat_scanner_version)\"" "${LIBRECHAT_DIR}/index.html"
    grep -q "hermes-app/app.js?v=$(librechat_app_version)\"" "${LIBRECHAT_DIR}/index.html"
    docker() { printf '<html><body></body></html>'; }   # an image whose page changed
    printf 'kept' >"${LIBRECHAT_DIR}/index.html"
    bats_run _librechat_page
    [ "$status" -ne 0 ] && [ "$(cat "${LIBRECHAT_DIR}/index.html")" = kept ]
    rm -rf "$LIBRECHAT_DIR"
}

@test "the app's manifest: the chat's name, the whole host, its own icons with the version, or LibreChat's" {
    LIBRECHAT_TITLE="Acme Chat"
    librechat_manifest_json v1 true | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["name"] == m["short_name"] == "Acme Chat" and m["display"] == "standalone", m
assert m["id"] == m["start_url"] == m["scope"] == "/", m
icons = {(i["sizes"], i["purpose"]): i["src"] for i in m["icons"]}
assert icons == {("192x192", "any"): "/hermes-app/icon-192.png?v=v1", ("512x512", "any"): "/hermes-app/icon-512.png?v=v1",
                 ("512x512", "maskable"): "/hermes-app/icon-maskable-512.png?v=v1"}, icons'
    librechat_manifest_json v1 false | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert [i["src"] for i in m["icons"]] == ["/assets/icon-192x192.png", "/assets/maskable-icon.png"], m["icons"]'
}

@test "the run puts the app's script and manifest next to LibreChat's files, and nothing the app no longer uses" {
    IFS=$'\n\t'                                          # as in install.sh
    LIBRECHAT_DIR=$(mktemp -d); DRY_RUN=false
    mkdir -p "${LIBRECHAT_DIR}/app"
    printf 'old' >"${LIBRECHAT_DIR}/app/icon-192.png"   # icons of an earlier run, and no Pillow now
    _librechat_app
    cmp -s "${LIBRECHAT_DIR}/app/app.js" <(printf '%s' "$(cat "$(librechat_app_source)/app.js")")
    [ ! -e "${LIBRECHAT_DIR}/app/icon-192.png" ]
    python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); assert m["icons"][0]["src"].startswith("/assets/"), m' \
        "${LIBRECHAT_DIR}/app/manifest.webmanifest"
    rm -rf "$LIBRECHAT_DIR"
}

@test "the app's icons: the title's initial on the colour, every size, maskable and Apple's full bleed, drawn once" {
    agent_python PIL
    LIBRECHAT_TITLE="  acme chat"
    [ "$(librechat_app_letter)" = A ]
    dir=$(mktemp -d)
    out=$("$HPY" - "$dir" S "#10a37f" < <(_librechat_icon_script))
    [ "$out" = "icon-192.png icon-512.png icon-maskable-512.png apple-touch-icon.png favicon-32.png favicon-16.png" ]
    [ -z "$("$HPY" - "$dir" S "#10a37f" < <(_librechat_icon_script))" ]   # the same again: nothing rewritten
    "$HPY" - "$dir" <<'PY'
import os, sys
from PIL import Image
d = sys.argv[1]
for name, size in {"icon-192.png": 192, "icon-512.png": 512, "icon-maskable-512.png": 512,
                   "apple-touch-icon.png": 180, "favicon-32.png": 32, "favicon-16.png": 16}.items():
    assert Image.open(os.path.join(d, name)).size == (size, size), name
assert Image.open(os.path.join(d, "apple-touch-icon.png")).mode == "RGB"          # no alpha: iOS shows it black
ground = (0x10, 0xA3, 0x7F)
mask = Image.open(os.path.join(d, "icon-maskable-512.png")).convert("RGBA")
assert mask.getpixel((0, 0)) == ground + (255,), mask.getpixel((0, 0))             # full bleed
icon = Image.open(os.path.join(d, "icon-512.png")).convert("RGBA")
assert icon.getpixel((0, 0))[3] == 0 and icon.getpixel((256, 12))[:3] == ground     # corners cut, the ground coloured
assert any(c == (255, 255, 255) for _, c in icon.crop((150, 150, 362, 362)).convert("RGB").getcolors(1 << 16))
PY
    rm -rf "$dir"
}

@test "the app's version covers its script, its name, its colour and the drawing" {
    v1=$(librechat_app_version)
    [[ $v1 =~ ^[0-9a-f]{12}$ ]]
    [ "$(LIBRECHAT_TITLE="Other Chat" librechat_app_version)" != "$v1" ]
    [ "$(LIBRECHAT_APP_COLOR="#000000" librechat_app_version)" != "$v1" ]
    src=$(mktemp -d); mkdir -p "${src}/bot/librechat/app"
    cp "$(librechat_app_source)/app.js" "${src}/bot/librechat/app/"
    [ "$(SCRIPT_DIR=$src librechat_app_version)" = "$v1" ]
    printf '\n' >>"${src}/bot/librechat/app/app.js"
    [ "$(SCRIPT_DIR=$src librechat_app_version)" != "$v1" ]
    rm -rf "$src"
}

@test "the app's button, driven through: Chrome's own dialog, the iPhone's two steps, gone once dismissed, never in the app" {
    command -v node >/dev/null || skip "node is not installed"
    node --check "$REPO_ROOT/bot/librechat/app/app.js"
    timeout 60 node "$REPO_ROOT/tests/bats/app-ui.js" "$REPO_ROOT/bot/librechat/app/app.js"
}

@test "the scanner's OpenCV is installed only with its pinned checksum" {
    [[ $_LC_SCANNER_SRC == "https://raw.githubusercontent.com/puffinsoft/jscanify/v1.4.0/src" ]]
    [[ $_LC_SCANNER_OPENCV_SHA =~ ^[0-9a-f]{64}$ ]]
    src=$(mktemp -d); DRY_RUN=false   # not "tmp": the function under test has a local of that name
    printf 'library' >"${src}/source"
    fetch() { cat "${src}/source"; }
    _librechat_fetch_pinned "${src}/lib.js" https://example.com/lib.js "$(sha256sum "${src}/source" | cut -d' ' -f1)"
    [ "$(cat "${src}/lib.js")" = library ]
    bats_run _librechat_fetch_pinned "${src}/other.js" https://example.com/lib.js "$(printf '%064d' 0)"
    [ "$status" -ne 0 ] && [ ! -e "${src}/other.js" ]
    [ -z "$(find "$src" -name 'other.js.*')" ]           # no half file left behind
    rm -rf "$src"
}

@test "the scanner's PDF: one page per shot, as wide as A4, a cross-reference table that points right" {
    command -v node >/dev/null || skip "node is not installed"
    tmp=$(mktemp -d)
    node -e '
const s = require(process.argv[1]);
const jpg = Buffer.from("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=", "base64");
const pdf = s.buildPdf([{jpeg: new Uint8Array(jpg), width: 1654, height: 2339}, {jpeg: new Uint8Array(jpg), width: 2400, height: 1600}]);
require("fs").writeFileSync(process.argv[2], Buffer.from(pdf));
if (s.scanFileName(new Date(2026, 8, 28, 14, 5)) !== "Scan 2026-09-28 14-05.pdf") process.exit(3);
let threw = false; try { s.buildPdf([]); } catch (e) { threw = true; } if (!threw) process.exit(4);
' "$REPO_ROOT/bot/librechat/scanner/scan.js" "${tmp}/scan.pdf"
    python3 - "${tmp}/scan.pdf" <<'PY'
import re, sys
b = open(sys.argv[1], "rb").read()
assert b.startswith(b"%PDF-1.4") and b.rstrip().endswith(b"%%EOF")
start = int(re.search(rb"startxref\n(\d+)\n", b).group(1))
assert b[start:start + 4] == b"xref", b[start:start + 20]
count = int(re.search(rb"xref\n0 (\d+)\n", b[start:]).group(1))
offsets = re.findall(rb"(\d{10}) 00000 n \n", b[start:])
assert len(offsets) == count - 1
for n, off in enumerate(offsets, 1):
    assert b[int(off):].startswith(b"%d 0 obj" % n), n
assert b.count(b"/Type /Page ") == 2
assert b"/MediaBox [0 0 595.28 841.81]" in b and b"/MediaBox [0 0 595.28 396.85]" in b
assert b.count(b"/Filter /DCTDecode") == 2
PY
    rm -rf "$tmp"
}

@test "a new scanner, worker or OpenCV pin gives the page a new version, which all of it is fetched with" {
    IFS=$'\n\t'                                          # as in install.sh
    v1=$(librechat_scanner_version)
    [[ $v1 =~ ^[0-9a-f]{12}$ ]]
    # the version covers the pins: the same files with another pin are another version
    v3=$( { cat "$(librechat_scanner_source)/scan.js" "$(librechat_scanner_source)/scan-worker.js"
            printf '%s' "changed"; } | sha256sum | cut -c1-12 )
    [ "$v1" != "$v3" ]
    # and every file of the scanner's own: a changed worker is another version
    src=$(mktemp -d); mkdir -p "${src}/bot/librechat/scanner"
    cp "$(librechat_scanner_source)/scan.js" "$(librechat_scanner_source)/scan-worker.js" "${src}/bot/librechat/scanner/"
    [ "$(SCRIPT_DIR=$src librechat_scanner_version)" = "$v1" ]
    printf '\n' >>"${src}/bot/librechat/scanner/scan-worker.js"
    [ "$(SCRIPT_DIR=$src librechat_scanner_version)" != "$v1" ]
    rm -rf "$src"
    # the page starts the worker with the version, the worker fetches OpenCV with it
    grep -q 'BASE + "scan-worker.js" + QUERY' "$(librechat_scanner_source)/scan.js"
    grep -q 'importScripts("opencv.js" + query)' "$(librechat_scanner_source)/scan-worker.js"
}

@test "the installer puts every file of the scanner's own next to OpenCV and drops what it no longer uses" {
    IFS=$'\n\t'                                          # as in install.sh
    LIBRECHAT_DIR=$(mktemp -d); DRY_RUN=false
    _librechat_fetch_pinned() { :; }
    mkdir -p "${LIBRECHAT_DIR}/scanner"
    printf 'cv' >"${LIBRECHAT_DIR}/scanner/opencv.js"
    printf 'old' >"${LIBRECHAT_DIR}/scanner/jscanify.js"      # an earlier scanner's library
    _librechat_scanner
    [ ! -e "${LIBRECHAT_DIR}/scanner/jscanify.js" ] && [ "$(cat "${LIBRECHAT_DIR}/scanner/opencv.js")" = cv ]
    for f in scan.js scan-worker.js; do
        cmp -s "${LIBRECHAT_DIR}/scanner/${f}" <(printf '%s' "$(cat "$(librechat_scanner_source)/${f}")")
    done
    rm -rf "$LIBRECHAT_DIR"
}

@test "the scanner's scripts parse" {
    command -v node >/dev/null || skip "node is not installed"
    node --check "$REPO_ROOT/bot/librechat/scanner/scan.js"
    node --check "$REPO_ROOT/bot/librechat/scanner/scan-worker.js"
}

# The worker against the real libraries, where an installed scanner has them.
scanner_libs() {                  # LIBS: where the installed, pinned OpenCV is — or the test is skipped
    LIBS="${LIBRECHAT_DIR}/scanner"
    command -v node >/dev/null || skip "node is not installed"
    [[ -f ${LIBS}/opencv.js ]] || skip "the scanner's OpenCV is not installed here"
    [[ $(sha256sum "${LIBS}/opencv.js" | cut -d' ' -f1) == "$_LC_SCANNER_OPENCV_SHA" ]] ||
        skip "the installed OpenCV is not the pinned one"
}

@test "the scanner's worker starts OpenCV in a worker's own scope, finds the page and straightens it" {
    scanner_libs
    # Bounded from outside: a promise resolved with OpenCV's module — a thenable —
    # resolves again forever and holds the whole thread; no timer inside fires.
    timeout 120 node - "$REPO_ROOT/bot/librechat/scanner/scan-worker.js" "$LIBS" <<'JS'
const fs = require("fs"), path = require("path"), vm = require("vm");
const [worker, libs] = process.argv.slice(2);
const posted = [], loaded = [];
const scope = {                   // what a browser gives a worker, and nothing of Node
  location: { href: "https://chat.example.com/hermes-scan/scan-worker.js?v=test", search: "?v=test" },
  setTimeout, clearTimeout, console, atob, btoa, fetch, performance, TextDecoder, TextEncoder,
  crypto: require("crypto").webcrypto,
  postMessage: (m) => posted.push(m),
  importScripts: (...urls) => urls.forEach((u) => {
    loaded.push(u);
    const name = u.split("?")[0];
    vm.runInContext(fs.readFileSync(path.join(libs, name), "utf8"), scope, { filename: name });
  }),
};
scope.self = scope;
vm.createContext(scope);
const t0 = Date.now();
vm.runInContext(fs.readFileSync(worker, "utf8"), scope, { filename: "scan-worker.js" });

function page(w, h, quad) {       // a light quadrilateral on a dark ground, RGBA
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const s = quad.map((p, i) => { const q = quad[(i + 1) % 4]; return (q.x - p.x) * (y + 0.5 - p.y) - (q.y - p.y) * (x + 0.5 - p.x); });
    const v = quad.length && (s.every((d) => d >= 0) || s.every((d) => d <= 0)) ? 245 : 40, o = (y * w + x) * 4;
    data[o] = data[o + 1] = data[o + 2] = v; data[o + 3] = 255;
  }
  return { data, width: w, height: h };
}
function fail(msg) { console.error(msg); process.exit(1); }
function answer(id) { const m = posted.find((p) => p.id === id); if (!m) fail("no answer to " + id); return m; }

(function wait() {
  const boot = posted.find((m) => m.type);
  if (!boot) { if (Date.now() - t0 > 90000) fail("the worker never said ready or error"); return setTimeout(wait, 100); }
  if (boot.type !== "ready") fail("the worker failed: " + boot.message);
  if (loaded.join(" ") !== "opencv.js?v=test") fail("OpenCV fetched without the version, or more than OpenCV: " + loaded);

  const quad = [{ x: 150, y: 80 }, { x: 480, y: 110 }, { x: 450, y: 420 }, { x: 120, y: 390 }];
  scope.onmessage({ data: { id: 1, type: "detect", image: page(640, 480, quad) } });
  const pages = answer(1).pages || [];
  if (pages.length !== 1) fail("one page, not " + JSON.stringify(answer(1)));
  const c = pages[0];
  const want = { topLeftCorner: quad[0], topRightCorner: quad[1], bottomRightCorner: quad[2], bottomLeftCorner: quad[3] };
  for (const k of Object.keys(want)) {
    if (Math.abs(c[k].x - want[k].x) > 6 || Math.abs(c[k].y - want[k].y) > 6) fail(k + " " + JSON.stringify(c[k]));
  }
  scope.onmessage({ data: { id: 2, type: "extract", image: page(640, 480, quad), cuts: [{ corners: c, width: 300, height: 400 }], filter: "colour" } });
  const img = (answer(2).images || [])[0];
  if (!img || img.width !== 300 || img.height !== 400 || img.data.length !== 300 * 400 * 4) fail("extract: " + JSON.stringify(answer(2)).slice(0, 200));
  let sum = 0; for (let i = 0; i < img.data.length; i += 4) sum += img.data[i];
  if (sum / (300 * 400) < 200) fail("the straightened page is not the page");
  scope.onmessage({ data: { id: 3, type: "detect", image: page(640, 480, []) } });
  if (!answer(3).pages || answer(3).pages.length) fail("a blank frame has a page: " + JSON.stringify(answer(3)));
  process.exit(0);
})();
JS
}

@test "the scanner's worker frees every contour it looks at: this OpenCV build never frees one by itself" {
    scanner_libs
    ! grep -q FinalizationRegistry "${LIBS}/opencv.js"   # nothing collects a handle that is dropped
    timeout 120 node - "$REPO_ROOT/bot/librechat/scanner/scan-worker.js" "$LIBS" <<'JS'
const [worker, libs] = process.argv.slice(2);
const cv = require(libs + "/opencv.js");
const { findCorners } = require(worker);
function busy(w, h) {             // a page on a desk full of small things: a thousand contours
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const onPage = x > 120 && x < 360 && y > 60 && y < 300;
    const dot = ((x >> 3) + (y >> 3)) % 3 === 0 && x % 8 > 1 && y % 8 > 1;
    const v = onPage ? 240 : dot ? 220 : 30, o = (y * w + x) * 4;
    data[o] = data[o + 1] = data[o + 2] = v; data[o + 3] = 255;
  }
  return { data, width: w, height: h };
}
(function wait() {
  if (typeof cv.Mat !== "function") return setTimeout(wait, 20);
  const handed = [], get = cv.MatVector.prototype.get;
  cv.MatVector.prototype.get = function (i) { const m = get.call(this, i); handed.push(m); return m; };
  if (!findCorners(cv, busy(480, 360))) { console.error("the page on the busy desk was not found"); process.exit(1); }
  const alive = handed.filter((m) => !m.isDeleted()).length;
  if (handed.length < 500 || alive) { console.error(alive + " of " + handed.length + " contours left behind"); process.exit(1); }
  process.exit(0);
})();
JS
}

@test "the scanner finds every sheet — on a light desk, through grain and folds, turned, in soft shadow, on colour, side by side — at both sizes" {
    scanner_libs
    timeout 300 node - "$REPO_ROOT/bot/librechat/scanner/scan-worker.js" "$LIBS" "$REPO_ROOT/tests/bats/scanner-scenes.js" <<'JS'
const [worker, libs, scenes] = process.argv.slice(2);
const cv = require(libs + "/opencv.js");
const { findPages } = require(worker);
const { SCENES, scene } = require(scenes);
const KEYS = ["topLeftCorner", "topRightCorner", "bottomRightCorner", "bottomLeftCorner"];
function off(c, quad, s) { return Math.max(...KEYS.map((k, i) => Math.hypot(c[k].x - quad[i][0] * s, c[k].y - quad[i][1] * s))); }
(function wait() {
  if (typeof cv.Mat !== "function") return setTimeout(wait, 20);
  const bad = [];
  for (const s of [1, 2]) {                     // the live preview, and a shot measured again at twice its size
    for (const [name, spec] of Object.entries(SCENES)) {
      const pages = findPages(cv, scene(cv, spec, s));
      // a found sheet that is none of the scene's is wrong, always
      for (const c of pages) {
        const best = Math.min(...spec.sheets.map((q) => off(c, q, s)));
        if (best > 6 * s) bad.push(`${name} at ${s}x: a sheet off by ${best.toFixed(0)} px`);
      }
      // unseen is allowed only where no pass can see it
      if (!spec.hard && pages.length !== spec.sheets.length) bad.push(`${name} at ${s}x: ${pages.length} of ${spec.sheets.length} sheets`);
    }
  }
  if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  process.exit(0);
})();
JS
}

@test "the scanner's Document filter makes the paper white in light and shadow alike, and the ink dark" {
    scanner_libs
    timeout 120 node - "$REPO_ROOT/bot/librechat/scanner/scan-worker.js" "$LIBS" "$REPO_ROOT/tests/bats/scanner-scenes.js" <<'JS'
const [worker, libs, scenes] = process.argv.slice(2);
const cv = require(libs + "/opencv.js");
const { findCorners, extract } = require(worker);
const { SCENES, scene } = require(scenes);
function region(im, x0, y0, x1, y1) {            // paper: the 95th percentile of a region, ink: the 5th
  const v = [];
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) v.push(im.data[4 * (y * im.width + x)]);
  v.sort((a, b) => a - b);
  return { paper: v[Math.floor(v.length * 0.95)], ink: v[Math.floor(v.length * 0.05)] };
}
(function wait() {
  if (typeof cv.Mat !== "function") return setTimeout(wait, 20);
  const img = scene(cv, SCENES["light desk, soft shadow"], 2), c = findCorners(cv, img);
  const [colour, doc] = ["colour", "document"].map((f) => extract(cv, img, [{ corners: c, width: 600, height: 850 }], f)[0]);
  const lit = [350, 100, 590, 400], shade = [10, 600, 250, 840];   // top right in the light, bottom left in the shadow
  const was = region(colour, ...shade), lightNow = region(doc, ...lit), shadeNow = region(doc, ...shade);
  const bad = [];
  if (was.paper > 180) bad.push("the scene has no shadow to take out: " + JSON.stringify(was));
  if (lightNow.paper < 245 || shadeNow.paper < 245) bad.push("paper not white: " + JSON.stringify({ lightNow, shadeNow }));
  if (lightNow.ink > 60 || shadeNow.ink > 60) bad.push("ink not dark: " + JSON.stringify({ lightNow, shadeNow }));
  if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  process.exit(0);
})();
JS
}

@test "a cut gets its margin on every edge, sheets are read in rows, and the strip makes documents" {
    command -v node >/dev/null || skip "node is not installed"
    node -e '
const s = require(process.argv[1]);
const K = ["topLeftCorner", "topRightCorner", "bottomRightCorner", "bottomLeftCorner"];
function at(c) { return K.map((k) => Math.round(c[k].x) + "," + Math.round(c[k].y)).join(" "); }
function check(what, got, want) { if (got !== want) { console.error(what + ": " + got + " != " + want); process.exit(1); } }
const page = { topLeftCorner: { x: 100, y: 100 }, topRightCorner: { x: 300, y: 100 },
               bottomRightCorner: { x: 300, y: 400 }, bottomLeftCorner: { x: 100, y: 400 } };
check("margin", at(s.withMargin(page, 0.02, 1000, 1000)), "96,96 304,96 304,404 96,404");   // 2% of the shorter side
check("kept in the frame", at(s.expanded(page, 150, 1000, 1000)), "0,0 450,0 450,550 0,550");
const q = (x, y) => ({ topLeftCorner: { x, y }, topRightCorner: { x: x + 100, y },
                       bottomRightCorner: { x: x + 100, y: y + 200 }, bottomLeftCorner: { x, y: y + 200 } });
check("reading order", s.readingOrder([q(400, 10), q(10, 300), q(200, 20), q(5, 5)]).map((c) => c.topLeftCorner.x).join(" "), "5 200 400 10");
const B = s.BREAK, a = { n: "a" }, b = { n: "b" }, c = { n: "c" }, names = (l) => l.map((x) => (x === B ? "|" : x.n)).join("");
check("breaks that separate nothing", names(s.tidy([B, a, B, B, b, B])), "a|b");
check("documents", JSON.stringify(s.documents([a, B, b, c]).map((d) => d.map((x) => x.n))), JSON.stringify([["a"], ["b", "c"]]));
check("earlier, across a break", names(s.moved([a, B, b, c], b, -1)), "ab|c");
check("later, emptying a document", names(s.moved([a, B, b], a, 1)), "ab");
check("second of two PDFs", s.scanFileName(new Date(2026, 8, 28, 14, 5), 2), "Scan 2026-09-28 14-05 (2).pdf");
' "$REPO_ROOT/bot/librechat/scanner/scan.js"
}

@test "corners dragged by hand are ordered around their centre, starting top left" {
    command -v node >/dev/null || skip "node is not installed"
    node -e '
const { ordered } = require(process.argv[1]);
const K = ["topLeftCorner", "topRightCorner", "bottomRightCorner", "bottomLeftCorner"];
const page = [{ x: 10, y: 10 }, { x: 110, y: 12 }, { x: 108, y: 150 }, { x: 8, y: 148 }];
const c = ordered([page[2], page[0], page[3], page[1]]);
if (!K.every((k, i) => c[k] === page[i])) process.exit(2);
const d = ordered([{ x: 60, y: 0 }, { x: 120, y: 60 }, { x: 60, y: 120 }, { x: 0, y: 60 }]);   // turned 45 degrees
if (new Set(K.map((k) => d[k])).size !== 4) process.exit(3);
' "$REPO_ROOT/bot/librechat/scanner/scan.js"
}

@test "the scanner's screen, driven through: one sheet, two, a new document, the corners, a page edited, taken again, deleted, two PDFs handed over" {
    command -v node >/dev/null || skip "node is not installed"
    timeout 60 node "$REPO_ROOT/tests/bats/scanner-ui.js" "$REPO_ROOT/bot/librechat/scanner/scan.js"
}

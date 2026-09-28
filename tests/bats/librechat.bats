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

# The document scanner: LibreChat is not rebuilt; its page gets one script tag
# and its static directory one more folder, both mounted, both with the switch.
@test "the scanner rides on LibreChat's own page and files, and goes with its switch" {
    out=$(librechat_compose_text)
    python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
v = d["services"]["api"]["volumes"]
assert "./index.html:/app/client/dist/index.html:ro" in v and "./scanner:/app/client/dist/hermes-scan:ro" in v, v
assert set(d["volumes"]) == {"mongo", "meili", "uploads", "images"}, d["volumes"]' <<<"$out"
    LIBRECHAT_SCANNER=false
    out=$(librechat_compose_text)
    [[ $out != *"hermes-scan"* && $out != *"index.html"* ]]
    python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin)' <<<"$out"
}

@test "the scanner's tag goes into LibreChat's page once, before </body>, with the script's checksum" {
    page='<html><head></head><body><div id="root"></div></body></html>'
    out=$(librechat_index_with_scanner abc123 <<<"$page")
    [[ $out == *'<div id="root"></div><script defer src="./hermes-scan/scan.js?v=abc123"></script></body>'* ]]
    bats_run librechat_index_with_scanner abc123 <<<"$out"
    [ "$status" -ne 0 ]                                  # never twice: the page must come from the image
    bats_run librechat_index_with_scanner abc123 <<<"<html></html>"
    [ "$status" -ne 0 ] && [[ $output == *"review the scanner"* ]]
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

@test "the installer puts every file of the scanner's own next to OpenCV, drops what it no longer uses, and the page asks for this version" {
    IFS=$'\n\t'                                          # as in install.sh
    LIBRECHAT_DIR=$(mktemp -d); DRY_RUN=false
    _librechat_fetch_pinned() { :; }
    docker() { printf '<html><body><div id="root"></div></body></html>'; }
    mkdir -p "${LIBRECHAT_DIR}/scanner"
    printf 'cv' >"${LIBRECHAT_DIR}/scanner/opencv.js"
    printf 'old' >"${LIBRECHAT_DIR}/scanner/jscanify.js"      # an earlier scanner's library
    _librechat_scanner
    [ ! -e "${LIBRECHAT_DIR}/scanner/jscanify.js" ] && [ "$(cat "${LIBRECHAT_DIR}/scanner/opencv.js")" = cv ]
    for f in scan.js scan-worker.js; do
        cmp -s "${LIBRECHAT_DIR}/scanner/${f}" <(printf '%s' "$(cat "$(librechat_scanner_source)/${f}")")
    done
    grep -q "hermes-scan/scan.js?v=$(librechat_scanner_version)\"" "${LIBRECHAT_DIR}/index.html"
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

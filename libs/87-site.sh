# shellcheck shell=bash
#
# The public face: a three-page static site — home, privacy policy, terms of
# service — served through the tunnel under its own hostname.
#
# It exists because the OAuth providers want it: Google publishes an external
# app only with these three links on an authorized domain, and Teams shows
# them in the app's details. The pages describe what is true — a private tool
# for one operator — and are rendered from bot/site/ with the operator's name
# and contact from configuration.
#
# nginx serves the directory on its own loopback port; the tunnel module
# publishes the hostname (see tunnel_hostnames / tunnel_ingress_rules).
#
# Order: BEFORE `assistant`. The assistant's Google side needs a refresh token
# that survives a week, and a token only becomes durable once the consent
# screen is published — which Google refuses to do while the privacy and terms
# links do not resolve. Those links are these pages. Running the assistant
# first produced a sign-in that worked and then expired seven days later, with
# nothing in the logs to connect the two. The module installs nginx itself if
# `dashboard` has not already, and listens on its own port, so nothing about
# the earlier position is load-bearing.

site_apply() {
    is_true "${SITE_ENABLED:-false}" || { log_skip "public site disabled (SITE_ENABLED=false)"; return 0; }
    log_step "Public site"
    local before=$CHANGE_COUNT
    _site_ensure_nginx
    _site_render
    _site_nginx
    converge_unit nginx.service "$before"
    _site_verify
}

site_url() { printf 'https://%s' "$SITE_HOSTNAME"; }

site_render_page() {          # site_render_page TEMPLATE -> html with the placeholders filled
    python3 - "$1" "$SITE_OWNER" "$SITE_CONTACT" "$BOT_PREFIX" <<'PY'
import sys, html
tpl, owner, contact, prefix = sys.argv[1:5]
text = open(tpl, encoding="utf-8").read()
for k, v in (("SITE_OWNER", owner), ("SITE_CONTACT", contact), ("BOT_PREFIX", prefix)):
    if not v:
        sys.exit(f"{k} is empty; the public site needs it")
    text = text.replace("${" + k + "}", html.escape(v))
if "${" in text:
    sys.exit("site template has an unexpanded placeholder")
sys.stdout.write(text)
PY
}

_site_ensure_nginx() {
    have_cmd nginx && { log_skip "nginx present"; return 0; }
    log_info "installing nginx"
    DEBIAN_FRONTEND=noninteractive run apt-get install -y nginx
    mark_changed
}

_site_render() {
    local tpl page
    ensure_dir "$SITE_ROOT" 0755
    for page in index privacy terms; do
        tpl="${SCRIPT_DIR}/bot/site/${page}.html.tpl"
        [[ -f $tpl ]] || die "missing site template ${tpl}"
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] render ${page}.html -> ${SITE_ROOT}"
            continue
        fi
        write_file "${SITE_ROOT}/${page}.html" 0644 <<<"$(site_render_page "$tpl")"
    done
}

_site_nginx_conf() {
    cat <<CONF
# Managed by setup-hermes-agent: the public pages behind ${SITE_HOSTNAME}.
server {
    listen 127.0.0.1:${SITE_PORT};
    server_name ${SITE_HOSTNAME};
    root ${SITE_ROOT};
    index index.html;
    location = /privacy { try_files /privacy.html =404; }
    location = /terms   { try_files /terms.html =404; }
    location / { try_files \$uri \$uri.html /index.html; }
    add_header Cache-Control "public, max-age=3600";
}
CONF
}

_site_nginx() {
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] nginx site ${SITE_HOSTNAME} on 127.0.0.1:${SITE_PORT}"
        return 0
    fi
    require_root "publishing the site"
    write_file /etc/nginx/sites-available/assistant-site 0644 <<<"$(_site_nginx_conf)"
    if [[ ! -L /etc/nginx/sites-enabled/assistant-site ]]; then
        run ln -sf /etc/nginx/sites-available/assistant-site /etc/nginx/sites-enabled/assistant-site
        mark_changed
    fi
    nginx -t >/dev/null 2>&1 || die "nginx configuration test failed"
}

_site_verify() {
    [[ $DRY_RUN == true ]] && return 0
    local code path
    for path in / /privacy /terms; do
        code=$(http_status "http://127.0.0.1:${SITE_PORT}${path}")
        [[ $code == 200 ]] || die "site: ${path} answers ${code} on loopback"
    done
    log_ok "public site  https://${SITE_HOSTNAME}/  /privacy  /terms"
}

site_uninstall() {
    run rm -f /etc/nginx/sites-enabled/assistant-site /etc/nginx/sites-available/assistant-site
    run rm -rf "$SITE_ROOT"
}

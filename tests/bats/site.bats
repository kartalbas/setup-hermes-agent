#!/usr/bin/env bats
#
# The public pages: rendered from the repository with the operator's name and
# contact, no placeholder left, HTML-escaped.

setup() {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT
    SITE_OWNER="Acme & Sons" SITE_CONTACT="agent@example.com" BOT_PREFIX="Acme"
}

@test "every page renders with owner, contact and prefix filled in" {
    local page out
    for page in index privacy terms; do
        out=$(site_render_page "$REPO_ROOT/bot/site/${page}.html.tpl")
        [[ $out == *"Acme &amp; Sons"* ]]
        [[ $out == *"agent@example.com"* ]]
        [[ $out != *'${'* ]]
    done
}

@test "an empty owner is refused instead of publishing a hole" {
    SITE_OWNER=""
    bats_run site_render_page "$REPO_ROOT/bot/site/privacy.html.tpl"
    [ "$status" -ne 0 ]
}

@test "the nginx block serves the three pages on loopback only" {
    SITE_HOSTNAME=assistant.example.com SITE_PORT=8081 SITE_ROOT=/var/www/x
    out=$(_site_nginx_conf)
    [[ $out == *"listen 127.0.0.1:8081;"* ]]
    [[ $out == *"server_name assistant.example.com;"* ]]
    [[ $out == *'try_files $uri $uri.html /index.html;'* ]]
}

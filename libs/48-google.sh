# shellcheck shell=bash
#
# Google — the private world: the project, its APIs and the OAuth client the
# Google assistant signs in with.
#
# Same shape as the azure module: a CLI the run installs, a sign-in the
# operator did once (as the agent's Google account), and everything the CLI
# can do done by the run. What it cannot do is the OAuth client: Google shut
# the OAuth-client admin API down in March 2026, so the Desktop client is the
# one thing created in the console — the run says exactly where and how, and
# refuses to pretend otherwise.
#
# Order: after `azure`, before `docker`.

google_apply() {
    is_true "${ASSISTANT_GOOGLE_ENABLED:-false}" || { log_skip "google not enabled (ASSISTANT_GOOGLE_ENABLED=false)"; return 0; }
    log_step "Google"
    _gcloud_ensure_cli
    _gcloud_require_login
    _gcloud_enable_apis
    _google_client_check
}

# The CLI runs as the service account: its sign-in and project live in that
# account's home, and the assistant later acts as the same Google identity.
gcloud_as_service() {
    if [[ $(id -un) == "$SERVICE_USER" ]]; then gcloud "$@"
    else runuser -u "$SERVICE_USER" -- gcloud "$@"; fi
}

_gcloud_ensure_cli() {
    if have_cmd gcloud; then
        log_skip "google cloud cli present ($(gcloud --version 2>/dev/null | head -n1 | sed 's/Google Cloud SDK //'))"
        return 0
    fi
    log_info "installing the Google Cloud CLI"
    ensure_dir /etc/apt/keyrings 0755
    run_sh "curl --proto '=https' --tlsv1.2 -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg"
    run chmod a+r /etc/apt/keyrings/cloud.google.gpg
    write_file /etc/apt/sources.list.d/google-cloud-sdk.sources 0644 <<EOF
Types: deb
URIs: https://packages.cloud.google.com/apt
Suites: cloud-sdk
Components: main
Signed-By: /etc/apt/keyrings/cloud.google.gpg
EOF
    DEBIAN_FRONTEND=noninteractive run apt-get update
    DEBIAN_FRONTEND=noninteractive run apt-get install -y google-cloud-cli
    mark_changed
}

_gcloud_require_login() {
    local account project
    if [[ $DRY_RUN == true ]] && ! have_cmd gcloud; then
        log_info "[dry-run] would require gcloud signed in as ${ASSISTANT_GOOGLE_ACCOUNT} with project ${GOOGLE_PROJECT}"
        return 0
    fi
    account=$(gcloud_as_service auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
    if [[ ${account,,} != "${ASSISTANT_GOOGLE_ACCOUNT,,}" ]]; then
        log_error "gcloud is not signed in as ${ASSISTANT_GOOGLE_ACCOUNT} for ${SERVICE_USER} (found '${account:-nobody}')."
        log_error "  This is a browser step and cannot be scripted. Run, as ${SERVICE_USER}:"
        log_error "    sudo -u ${SERVICE_USER} -H gcloud auth login --no-launch-browser"
        log_error "  Account to use: ${ASSISTANT_GOOGLE_ACCOUNT}"
        die "google: not signed in"
    fi
    project=$(gcloud_as_service config get-value project 2>/dev/null)
    if [[ $project != "$GOOGLE_PROJECT" ]]; then
        run gcloud_as_service config set project "$GOOGLE_PROJECT"
        mark_changed
    fi
    log_ok "gcloud signed in as ${account} (project ${GOOGLE_PROJECT})"
}

# The APIs the assistant calls. Enabling is idempotent on Google's side; the
# list is compared first so a converged run makes no call.
_gcloud_enable_apis() {
    local IFS=$' \t\n' want enabled missing=()
    if [[ $DRY_RUN == true ]] && ! have_cmd gcloud; then
        log_info "[dry-run] would enable APIs: ${GOOGLE_APIS}"
        return 0
    fi
    enabled=$(gcloud_as_service services list --enabled --format='value(config.name)' 2>/dev/null)
    for want in $GOOGLE_APIS; do
        grep -qx "${want}.googleapis.com" <<<"$enabled" || missing+=("${want}.googleapis.com")
    done
    if (( ${#missing[@]} == 0 )); then
        log_skip "APIs enabled: ${GOOGLE_APIS}"
        return 0
    fi
    log_info "  enabling ${missing[*]}"
    run gcloud_as_service services enable "${missing[@]}"
    mark_changed
}

# The OAuth "Desktop app" client — the one manual step, named precisely.
_google_client_check() {
    if secret_nonempty "$ASSISTANT_GOOGLE_CLIENT_ID_VAR" && secret_nonempty "$ASSISTANT_GOOGLE_CLIENT_SECRET_VAR"; then
        log_ok "oauth client   $(secret_get "$ASSISTANT_GOOGLE_CLIENT_ID_VAR" | cut -c1-12)… (from the secrets file)"
        return 0
    fi
    log_error "the Google OAuth client is missing from the secrets file (${ASSISTANT_GOOGLE_CLIENT_ID_VAR}, ${ASSISTANT_GOOGLE_CLIENT_SECRET_VAR})."
    log_error "  Google's OAuth-client admin API was shut down in March 2026, so this one is made in the console — once:"
    log_error "    1. https://console.cloud.google.com/auth/overview?project=${GOOGLE_PROJECT}  (signed in AS ${ASSISTANT_GOOGLE_ACCOUNT})"
    log_error "       app name, audience External, support e-mail ${ASSISTANT_GOOGLE_ACCOUNT}"
    log_error "    2. Audience: add ${ASSISTANT_GOOGLE_ACCOUNT} as a test user, then PUBLISH the app (In production)."
    log_error "       In Testing status refresh tokens die after 7 days; published, they do not."
    log_error "    3. Clients -> Create client -> type Desktop app."
    log_error "    4. Put client id and secret into the secrets file as ${ASSISTANT_GOOGLE_CLIENT_ID_VAR} and ${ASSISTANT_GOOGLE_CLIENT_SECRET_VAR}."
    defer_failure "google: OAuth client not in the secrets file; the assistant's Google side waits for it"
    return 0
}

google_uninstall() { return 0; }

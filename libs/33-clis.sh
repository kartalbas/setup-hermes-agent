# shellcheck shell=bash
#
# The subscription CLIs the agent delegates to.
#
# Both install per-user into the invoking account's ~/.local, and both keep
# their credentials there too. That is why they are installed AS the service
# account rather than system-wide: the binary and the sign-in have to belong to
# the same account, and an administrator's sign-in does not carry over.
#
# The one step no script can take is the browser authorisation. This module
# installs, verifies, and then tells you exactly what to run — rather than
# leaving an unauthenticated CLI to fail when the first message arrives.

clis_apply() {
    if ! is_true "${CLIS_MANAGE:-false}"; then
        log_skip "subscription CLIs unmanaged (CLIS_MANAGE=false)"
        return 0
    fi
    [[ -n ${CLIS_INSTALL:-} ]] || { log_skip "no CLIs listed in CLIS_INSTALL"; return 0; }

    log_step "Subscription CLIs"
    require_root "installing for ${SERVICE_USER:-the service account}"

    local user home cli IFS=$' \t\n'
    user=${SERVICE_USER:-$(id -un)}
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $home ]] || die "cannot determine the home directory of ${user}"

    local -a needs_login=()
    for cli in $CLIS_INSTALL; do
        _cli_install "$cli" "$user" "$home" || die "could not install ${cli}"
        _cli_authenticated "$cli" "$user" "$home" || needs_login+=("$cli")
    done

    _cli_report_login "$user" ${needs_login+"${needs_login[@]}"}
}

# ---------------------------------------------------------------------------

_cli_url() {
    case $1 in
        agy)    printf '%s' "${CLI_URL_AGY:-}" ;;
        claude) printf '%s' "${CLI_URL_CLAUDE:-}" ;;
        *)      return 1 ;;
    esac
}

_cli_present() {
    local cli=$1 user=$2
    runuser -u "$user" -- bash -lc "command -v ${cli}" 2>/dev/null
}

_cli_install() {
    local cli=$1 user=$2 home=$3 url found script

    if found=$(_cli_present "$cli" "$user"); then
        log_skip "${cli} present for ${user}: ${found}"
        return 0
    fi

    url=$(_cli_url "$cli") || die "no installer URL configured for '${cli}' — add CLI_URL_${cli^^} to config/install.conf"
    [[ -n $url ]] || die "CLI_URL_${cli^^} is empty in config/install.conf"

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] install ${cli} for ${user} from ${url}"
        return 0
    fi

    # Downloaded and inspected before running, not piped straight into a shell:
    # a truncated transfer otherwise executes a syntactically valid prefix.
    script="${PROVISIONER_STATE_DIR}/install-${cli}.sh"
    ensure_dir "$PROVISIONER_STATE_DIR" 0750
    fetch "$url" -o "$script" || { log_warn "could not download the ${cli} installer"; return 1; }
    [[ -s $script ]] || { log_warn "the ${cli} installer is empty"; return 1; }
    head -n1 "$script" | grep -q '^#!' || { log_warn "the ${cli} installer does not look like a script"; return 1; }
    chmod 0755 "$script"

    log_info "installing ${cli} for ${user}"
    # As the service account, with its own HOME, and without a controlling
    # terminal so an installer that would prompt fails plainly instead of
    # hanging a provisioning run.
    run runuser -u "$user" -- env "HOME=${home}" bash "$script" </dev/null || {
        log_warn "the ${cli} installer exited non-zero"
        return 1
    }

    found=$(_cli_present "$cli" "$user") || {
        log_warn "${cli} still not on ${user}'s PATH after installing"
        log_warn "  it usually lands in ${home}/.local/bin — check that is on the PATH"
        return 1
    }
    mark_changed
    log_ok "${cli} installed: ${found}"
}

# Credentials are per-account and live under the account's home. A sign-in
# performed by an administrator does not carry over, and that is the usual
# reason a CLI works interactively and then fails as a service.
_cli_authenticated() {
    local cli=$1 user=$2 home=$3
    [[ $DRY_RUN == true ]] && return 0

    case $cli in
        claude)
            runuser -u "$user" -- env "HOME=${home}" bash -lc \
                'claude auth status 2>/dev/null' </dev/null | grep -q '"loggedIn": *true' ;;
        agy)
            # No status subcommand; the credential file is the signal.
            [[ -s "${home}/.gemini/antigravity-cli/antigravity-oauth-token" ]] ;;
        *)  return 0 ;;
    esac
}

_cli_report_login() {
    local user=$1; shift
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would check that each CLI is signed in for ${user}"
        return 0
    fi
    if (( $# == 0 )); then
        log_ok "every configured CLI is signed in for ${user}"
        return 0
    fi

    log_warn "not signed in for ${user}: $*"
    log_warn "  Authorisation happens in a browser and cannot be scripted."
    log_warn "  Run each of these, open the printed URL on your own machine, and"
    log_warn "  come back — the -H is what puts the credentials in the right home:"
    local cli
    for cli in "$@"; do
        log_warn "    sudo -u ${user} -H ${cli}"
    done
    log_warn "  Then re-run this provisioner; everything else is already in place."
}

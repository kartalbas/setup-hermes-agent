# shellcheck shell=bash
#
# Installing the agent itself, at a pinned revision.
#
# Two things here are not obvious and are the reason this module is more than a
# call to the vendor installer:
#
#   1. The vendor installer un-pins on re-run. Given an existing checkout it
#      moves to the default branch and fast-forwards, then reports that the
#      requested commit is "already newer" and exits successfully. A naive
#      re-run therefore drifts silently onto unreleased code while every check
#      still passes. The guard below skips the installer entirely when the
#      checkout already matches the recorded revision.
#
#   2. The installer offers to install a background service of its own after
#      setup, and under --non-interactive that prompt takes its default, which
#      is yes. It installs a *user-scope* unit. Combined with the system unit
#      this module's successor installs, that is two gateways writing one data
#      directory, whose stores are not built for concurrent writers. Running it
#      without a controlling terminal makes the prompt unreachable.

hermes_apply() {
    log_step "Agent"

    local sha
    sha=$(_hermes_resolve_ref)
    log_info "revision       ${HERMES_REF} -> ${sha}"

    if _hermes_at_revision "$sha"; then
        log_skip "already installed at ${sha:0:12}; skipping the vendor installer"
        _hermes_record_revision "$sha"
        _hermes_patch_email_folder
        return 0
    fi

    _hermes_run_installer "$sha"
    _hermes_patch_email_folder
    # Tell the service module the code changed underneath the unit: the vendor
    # refreshes its unit through `gateway install`, which is otherwise skipped
    # once one exists — right for a converged run, wrong after an upgrade.
    # shellcheck disable=SC2034  # read by src/70-service.sh
    HERMES_INSTALLER_RAN=true
    _hermes_assert_no_user_unit
    _hermes_record_revision "$sha"
}

# ---------------------------------------------------------------------------
# Revision resolution
#
# ls-remote rather than an API call: no rate limit, no token, no JSON parsing.
# The ^{} suffix dereferences an annotated tag to the commit it points at; a
# lightweight tag has no such entry and the plain ref is already the commit.
# The installer rejects abbreviated hashes, so this must be the full 40.
# ---------------------------------------------------------------------------
_hermes_resolve_ref() {
    local repo_url="https://github.com/${HERMES_REPO}.git"

    case $HERMES_REF_KIND in
        commit)
            [[ $HERMES_REF =~ ^[0-9a-fA-F]{40}$ ]] ||
                die "HERMES_REF_KIND=commit requires a full 40-character hash, got '${HERMES_REF}'"
            printf '%s' "${HERMES_REF,,}"
            return 0
            ;;
        tag)    local ref="refs/tags/${HERMES_REF}" ;;
        branch) local ref="refs/heads/${HERMES_REF}" ;;
        *)      die "unsupported HERMES_REF_KIND: ${HERMES_REF_KIND}" ;;
    esac

    local out sha
    out=$(git ls-remote "$repo_url" "$ref" "${ref}^{}" 2>/dev/null) ||
        die "cannot reach ${repo_url} to resolve ${HERMES_REF}"
    [[ -n $out ]] || die "${HERMES_REF_KIND} '${HERMES_REF}' not found in ${HERMES_REPO}"

    # Prefer the dereferenced commit when the tag is annotated.
    sha=$(awk '/\^\{\}$/ {print $1; found=1} END {if (!found) exit 1}' <<<"$out" 2>/dev/null) ||
        sha=$(awk 'NR==1{print $1}' <<<"$out")

    [[ $sha =~ ^[0-9a-fA-F]{40}$ ]] || die "resolved revision is not a full hash: '${sha}'"
    printf '%s' "${sha,,}"
}

# ---------------------------------------------------------------------------
# Pin guard
# ---------------------------------------------------------------------------

hermes_install_dir() {
    if [[ -n $INSTALL_DIR ]]; then
        printf '%s' "$INSTALL_DIR"
        return 0
    fi
    # The vendor picks its own target: /usr/local/lib/hermes-agent when it runs
    # as root, "$HERMES_HOME/hermes-agent" otherwise. We run it as the service
    # account, so the second is the one it can actually create — /usr/local/lib
    # belongs to root and no amount of pre-creating fixes that, because the
    # installer insists on making the directory itself with git.
    #
    # The FHS path is still probed first, so an installation made by an earlier
    # root run is adopted rather than duplicated.
    local candidate
    for candidate in /usr/local/lib/hermes-agent "${HERMES_HOME:-}/hermes-agent"; do
        [[ -n $candidate && -d ${candidate}/.git ]] && { printf '%s' "$candidate"; return 0; }
    done
    printf '%s' "${HERMES_HOME:-/usr/local/lib}/hermes-agent"
}

# True when the checkout is at the wanted commit AND the virtualenv actually
# works. Both matter: a matching SHA with a broken venv is not an installation.
_hermes_at_revision() {
    local want=$1 dir head
    dir=$(hermes_install_dir)

    [[ -d ${dir}/.git ]] || return 1
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1
    [[ $head == "$want" ]] || { log_debug "checkout is at ${head:0:12}, want ${want:0:12}"; return 1; }

    local py="${dir}/venv/bin/python"
    [[ -x $py ]] || { log_debug "no virtualenv interpreter at ${py}"; return 1; }
    "$py" -c 'import hermes_cli' >/dev/null 2>&1 ||
        { log_debug "virtualenv cannot import hermes_cli"; return 1; }

    return 0
}

# ---------------------------------------------------------------------------
# Running the vendor installer
# ---------------------------------------------------------------------------
_hermes_run_installer() {
    local sha=$1
    require_cmd curl git

    local script="${PROVISIONER_STATE_DIR}/install-upstream.sh"
    ensure_dir "$PROVISIONER_STATE_DIR" 0750

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] fetch ${HERMES_INSTALLER_URL}"
    else
        fetch "$HERMES_INSTALLER_URL" -o "$script" ||
            die "cannot download the vendor installer from ${HERMES_INSTALLER_URL}"
        [[ -s $script ]] || die "the downloaded installer is empty"
        head -n1 "$script" | grep -q '^#!' ||
            die "the downloaded installer does not look like a script"
        # It is downloaded by root and executed by the service account, so root
        # keeping it at 0700 makes it unreadable to the only account that runs
        # it — "Permission denied" from setsid, about a file that plainly exists
        # and is plainly executable. Give it to the account that needs it.
        chmod 0700 "$script"
        [[ -n ${SERVICE_USER:-} ]] && chown "${SERVICE_USER}:${SERVICE_GROUP}" "$script"
    fi

    # Name the target explicitly so every other module and the vendor agree on
    # one path. Do NOT create it: the installer clones into it and refuses a
    # directory that exists without a .git in it. Its parent is what has to be
    # there, and writable by the account that runs the clone.
    local dir parent; dir=$(hermes_install_dir); parent=${dir%/*}
    if [[ $DRY_RUN != true ]]; then
        [[ -d $parent ]] || die "the install directory's parent does not exist: ${parent}"
        if [[ -n ${SERVICE_USER:-} ]] && ! runuser -u "$SERVICE_USER" -- test -w "$parent"; then
            log_error "${SERVICE_USER} cannot write ${parent}, so it cannot create ${dir}."
            log_error "  The vendor installer creates that directory itself with git and"
            log_error "  refuses one that already exists, so pre-creating it does not help."
            log_error "  Point INSTALL_DIR at somewhere the account owns, or leave it empty"
            log_error "  to use \${HERMES_HOME}/hermes-agent."
            die "install directory is not creatable by the service account"
        fi
    fi

    local -a args=(--non-interactive --commit "$sha" --force-commit --dir "$dir")
    [[ -n $HERMES_HOME ]]  && args+=(--hermes-home "$HERMES_HOME")
    is_true "$HERMES_SKIP_BROWSER" && args+=(--skip-browser)
    is_true "$HERMES_SKIP_SKILLS"  && args+=(--no-skills)

    # --force-commit is what makes the pin survive: without it the installer
    # declines to move an existing checkout "backwards" onto the pinned commit.

    log_info "running the vendor installer (no controlling terminal)"
    _hermes_run_detached "$script" "${args[@]}"
    mark_changed
}

# Runs the installer with no controlling terminal and no stdin, as the service
# account. setsid detaches it from this terminal so the installer's own
# /dev/tty probe fails and its post-install service prompt is never reached.
_hermes_run_detached() {
    local script=$1; shift
    local -a cmd=("$script" "$@")

    local -a wrapper=()
    if [[ -n $SERVICE_USER ]] && [[ $(id -un) != "$SERVICE_USER" ]]; then
        require_root "running the installer as ${SERVICE_USER}"
        if have_cmd runuser; then
            wrapper=(runuser -u "$SERVICE_USER" --)
        else
            wrapper=(sudo -u "$SERVICE_USER" --)
        fi
    fi

    local -a env_args=(env)
    [[ -n $HERMES_HOME ]] && env_args+=("HERMES_HOME=${HERMES_HOME}")
    [[ -n $INSTALL_DIR ]] && env_args+=("HERMES_INSTALL_DIR=${INSTALL_DIR}")

    if have_cmd setsid; then
        run "${wrapper[@]}" "${env_args[@]}" setsid -w "${cmd[@]}" </dev/null
    else
        log_warn "setsid not available; the installer may see a terminal and prompt"
        run "${wrapper[@]}" "${env_args[@]}" "${cmd[@]}" </dev/null
    fi
}

# ---------------------------------------------------------------------------
# After the installer
# ---------------------------------------------------------------------------

# A user-scope unit here means the installer created one despite the precautions
# above. Left in place it becomes a second gateway on the same data directory.
_hermes_assert_no_user_unit() {
    [[ $DRY_RUN == true ]] && return 0
    have_cmd systemctl || return 0

    local home found=""
    home=$(getent passwd "${SERVICE_USER:-$(id -un)}" | cut -d: -f6)
    [[ -n $home && -f "${home}/.config/systemd/user/${SERVICE_NAME}.service" ]] &&
        found="${home}/.config/systemd/user/${SERVICE_NAME}.service"

    if [[ -n $found ]]; then
        log_warn "the vendor installer created a user-scope unit at ${found}"
        log_warn "removing it: a second gateway on one data directory corrupts its stores"
        run rm -f "$found"
        mark_changed
    else
        log_ok "no user-scope unit was created"
    fi
}

_hermes_record_revision() {
    local sha=$1
    ensure_dir "$PROVISIONER_STATE_DIR" 0750
    write_file "${PROVISIONER_STATE_DIR}/revision" 0644 <<EOF
${sha}
EOF
}

# hermes_cli — invoke the agent's CLI through its own interpreter.
# The shim on PATH belongs to the installing account and is not on root's PATH.
# hermes_cli, but as root.
#
# `gateway install --system` writes into /etc/systemd/system and refuses to run
# as anyone else — the vendor never self-elevates, by design. Everything else
# stays with the service account; this is the one exception, and what root
# leaves behind in the agent's home is handed straight back, because a
# root-owned file there breaks the service the first time it writes to it.
hermes_cli_root() {
    local dir py
    dir=$(hermes_install_dir)
    py="${dir}/venv/bin/python"

    if [[ ${DRY_RUN:-false} == true && ! -x $py ]]; then
        log_info "[dry-run] as root: ${py} -m hermes_cli.main$(printf ' %q' "$@")"
        return 0
    fi
    [[ -x $py ]] || die "no agent virtualenv at ${py}; the install did not complete"

    local -a env_args=(env)
    [[ -n $HERMES_HOME ]] && env_args+=("HERMES_HOME=${HERMES_HOME}")

    run "${env_args[@]}" "$py" -m hermes_cli.main "$@"
    local rc=$?
    _hermes_reclaim_home
    return "$rc"
}

_hermes_reclaim_home() {
    [[ $DRY_RUN == true ]] && return 0
    [[ -n ${HERMES_HOME:-} && -n ${SERVICE_USER:-} && -d ${HERMES_HOME} ]] || return 0
    local stray
    stray=$(find "$HERMES_HOME" -user root -print -quit 2>/dev/null || printf '')
    [[ -n $stray ]] || return 0
    log_info "handing back paths under ${HERMES_HOME} that root wrote"
    run find "$HERMES_HOME" -user root -exec chown "${SERVICE_USER}:${SERVICE_GROUP}" {} +
    mark_changed
    return 0
}

hermes_cli() {
    local dir py
    dir=$(hermes_install_dir)
    py="${dir}/venv/bin/python"

    # Under --dry-run the agent has not been installed, so there is nothing to
    # invoke; show the call that would be made instead of failing on its absence.
    if [[ ${DRY_RUN:-false} == true && ! -x $py ]]; then
        # %q rather than $*: IFS is newline/tab here, so "$*" would join the
        # arguments with newlines and print one word per line.
        log_info "[dry-run] ${py} -m hermes_cli.main$(printf ' %q' "$@")"
        return 0
    fi

    [[ -x $py ]] || die "no agent virtualenv at ${py}; the install did not complete"

    local -a wrapper=()
    if [[ -n $SERVICE_USER ]] && [[ $(id -un) != "$SERVICE_USER" ]]; then
        if have_cmd runuser; then wrapper=(runuser -u "$SERVICE_USER" --)
        else wrapper=(sudo -u "$SERVICE_USER" --); fi
    fi

    # HERMES_CONFIG_HOME is a bot's profile when a module runs inside
    # bot_context; otherwise the default home.
    local -a env_args=(env)
    local home=${HERMES_CONFIG_HOME:-$HERMES_HOME}
    [[ -n $home ]] && env_args+=("HERMES_HOME=${home}")

    run "${wrapper[@]}" "${env_args[@]}" "$py" -m hermes_cli.main "$@"
}

# ---------------------------------------------------------------------------
# A carried patch: the e-mail adapter polls a configurable folder.
#
# The pinned release hard-codes INBOX. One mailbox with Exchange rules that
# sort mail per alias into folders is how several bots share one account —
# each polls its own folder — so the two `imap.select("INBOX")` become
# `imap.select(os.environ.get("EMAIL_IMAP_FOLDER", "INBOX"))`. Two lines,
# idempotent, re-applied after every vendor update; candidate for upstream.
# ---------------------------------------------------------------------------
hermes_email_adapter_path() { printf '%s/plugins/platforms/email/adapter.py' "$(hermes_install_dir)"; }

hermes_patch_email_folder_file() {   # hermes_patch_email_folder_file FILE -> 0 patched, 3 already, 1 failed
    python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "EMAIL_IMAP_FOLDER" in s:
    sys.exit(3)
n = s.count('imap.select("INBOX")')
if n == 0:
    sys.exit("no imap.select(\"INBOX\") found; the adapter changed — review the patch")
s = s.replace('imap.select("INBOX")', 'imap.select(os.environ.get("EMAIL_IMAP_FOLDER", "INBOX"))')
if not re.search(r"^import os\b", s, re.M):
    s = "import os\n" + s
open(p, "w", encoding="utf-8").write(s)
compile(s, p, "exec")
PY
}

_hermes_patch_email_folder() {
    local f; f=$(hermes_email_adapter_path)
    [[ -f $f ]] || { log_warn "e-mail adapter not found at ${f}; folder patch skipped"; return 0; }
    if [[ $DRY_RUN == true ]]; then
        if grep -q EMAIL_IMAP_FOLDER "$f"; then log_skip "e-mail adapter folder patch present"
        else log_info "[dry-run] would patch ${f} for EMAIL_IMAP_FOLDER"; fi
        return 0
    fi
    local rc=0
    hermes_patch_email_folder_file "$f" || rc=$?
    case $rc in
        0) mark_changed; log_ok "e-mail adapter patched: folder from EMAIL_IMAP_FOLDER" ;;
        3) log_skip "e-mail adapter folder patch present" ;;
        *) die "could not patch the e-mail adapter for a configurable folder" ;;
    esac
}

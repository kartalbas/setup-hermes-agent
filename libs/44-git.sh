# shellcheck shell=bash
#
# Git configuration for the service account.
#
# The agent commits, pushes and reviews. Without an identity the first commit
# fails with "please tell me who you are", which surfaces as the agent being
# broken rather than as a missing setting.
#
# Written key by key rather than as a rendered file: the account's own git
# config is its to extend, and replacing it wholesale would discard anything the
# agent or an operator added and report a change on every run.

git_apply() {
    if ! is_true "${GIT_MANAGE:-false}"; then
        log_skip "git unmanaged (GIT_MANAGE=false)"
        return 0
    fi
    have_cmd git || die "GIT_MANAGE=true but git is not installed"

    log_step "Git"

    local user home cfg
    user=${SERVICE_USER:-$(id -un)}
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $home ]] || { log_warn "cannot determine the home directory of ${user}"; return 0; }
    cfg="${home}/.gitconfig"

    _git_identity "$user" "$cfg"
    _git_behaviour "$user" "$cfg"
    _git_safe_directories "$user" "$cfg"
    _git_ssh "$user" "$home"
    _git_extra "$user" "$cfg"
    _git_report "$user" "$cfg" "$home"
}

# ---------------------------------------------------------------------------
# SSH
#
# A key belonging to the service account, not to whoever ran the provisioner.
# The private half never leaves this host; the public half has to be pasted into
# the forge by hand, so the run ends by printing it.
# ---------------------------------------------------------------------------

git_ssh_key_path() {
    printf '%s/.ssh/id_%s' "$1" "${GIT_SSH_KEY_TYPE:-ed25519}"
}

_git_ssh() {
    local user=$1 home=$2
    is_true "${GIT_SSH_MANAGE:-false}" || { log_skip "ssh unmanaged (GIT_SSH_MANAGE=false)"; return 0; }
    have_cmd ssh-keygen || die "GIT_SSH_MANAGE=true but ssh-keygen is not available"

    local key; key=$(git_ssh_key_path "$home")
    ensure_dir "${home}/.ssh" 0700 "${SERVICE_USER:+${SERVICE_USER}:${SERVICE_GROUP}}"

    # The key itself is generated in the repository and deployed by the
    # credentials module, which runs first. This only configures its use.
    # Under a dry run the credentials module only announced the key, so its
    # absence here is expected and reporting it as a problem is noise.
    if [[ ! -f $key && $DRY_RUN != true ]]; then
        log_warn "no key at ${key}; the credentials module should have deployed one"
    fi
    _git_ssh_known_hosts "$user" "$home"
    _git_ssh_config "$user" "$home" "$key"
    _git_ssh_prefer "$user" "${home}/.gitconfig"
}

# Pre-seeding known_hosts stops the first connection asking a question nobody is
# there to answer. It is trust-on-first-use, so the fingerprints are printed:
# compare them against the ones the forge publishes.
_git_ssh_known_hosts() {
    local user=$1 home=$2 host IFS=$' \t\n'
    local kh="${home}/.ssh/known_hosts"
    [[ -n ${GIT_SSH_HOSTS:-} ]] || return 0
    have_cmd ssh-keyscan || die "GIT_SSH_HOSTS is set but ssh-keyscan is not available"

    for host in $GIT_SSH_HOSTS; do
        if [[ $DRY_RUN != true ]] && [[ -f $kh ]] && grep -q "^${host} \|^${host}," "$kh" 2>/dev/null; then
            log_skip "known_hosts already has ${host}"
            continue
        fi
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] ssh-keyscan ${host} >> ${kh}"
            continue
        fi
        local scanned
        # An empty known_hosts means the agent's first push stops on a question
        # nobody is there to answer, which reads as the agent having hung.
        scanned=$(ssh-keyscan -T 10 "$host" 2>/dev/null) || die "cannot reach ${host} to fetch its host key"
        [[ -n $scanned ]] || die "${host} returned no host key"
        printf '%s\n' "$scanned" | runuser -u "$user" -- tee -a "$kh" >/dev/null
        mark_changed
        log_ok "known_hosts += ${host}"
        printf '%s\n' "$scanned" | ssh-keygen -lf - 2>/dev/null | sed 's/^/       /' >&2
    done
    [[ -f $kh ]] && run chmod 0600 "$kh"
    return 0
}

_git_ssh_config() {
    local user=$1 home=$2 key=$3 host IFS=$' \t\n'
    [[ -n ${GIT_SSH_HOSTS:-} ]] || return 0

    local content=""
    for host in $GIT_SSH_HOSTS; do
        content+="Host ${host}"$'\n'
        content+="    User git"$'\n'
        content+="    IdentityFile ${key}"$'\n'
        # Use only this key: an account with several would otherwise offer them
        # all and can be refused for too many failures before reaching the right
        # one.
        content+="    IdentitiesOnly yes"$'\n'
        content+="    StrictHostKeyChecking yes"$'\n\n'
    done

    # Here-string, not a pipe: a pipeline runs write_file in a subshell where
    # the change flag it sets is discarded. tests/bats guards this.
    write_file "${home}/.ssh/config" 0600 "${SERVICE_USER:+${SERVICE_USER}:${SERVICE_GROUP}}" \
        <<<"# Managed by setup-hermes-agent."$'\n\n'"${content}"
}

# Rewrite https remotes to ssh, so a repository cloned over https still pushes
# with the key rather than asking for a password nobody can supply.
_git_ssh_prefer() {
    local user=$1 cfg=$2 host IFS=$' \t\n'
    is_true "${GIT_FORCE_SSH:-false}" || return 0
    for host in ${GIT_SSH_HOSTS:-}; do
        _git_set "$user" "$cfg" "url.git@${host}:.insteadOf" "https://${host}/"
    done
}

# _git_set USER FILE KEY VALUE — upsert one key, quietly skipping a no-op.
_git_set() {
    local user=$1 file=$2 key=$3 value=$4 current
    [[ -n $value ]] || return 0

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] git config ${key} = ${value}"
        return 0
    fi

    current=$(runuser -u "$user" -- git config --file "$file" --get "$key" 2>/dev/null || printf '')
    [[ $current == "$value" ]] && return 0

    runuser -u "$user" -- git config --file "$file" "$key" "$value" ||
        die "could not set git ${key}"
    mark_changed
    log_ok "${key} = ${value}"
}

_git_identity() {
    local user=$1 cfg=$2
    if [[ -z ${GIT_USER_NAME:-} || -z ${GIT_USER_EMAIL:-} ]]; then
        log_warn "GIT_USER_NAME or GIT_USER_EMAIL is unset — the agent cannot commit"
        log_warn "  set both in the site configuration; a shared mailbox address is fine"
        return 0
    fi
    _git_set "$user" "$cfg" user.name  "$GIT_USER_NAME"
    _git_set "$user" "$cfg" user.email "$GIT_USER_EMAIL"
}

_git_behaviour() {
    local user=$1 cfg=$2
    _git_set "$user" "$cfg" init.defaultBranch      "${GIT_DEFAULT_BRANCH:-main}"
    # Rebase on pull, and never open a merge editor: an agent that is asked for
    # a commit message by a blocking editor simply stops.
    _git_set "$user" "$cfg" pull.rebase             "${GIT_PULL_REBASE:-true}"
    _git_set "$user" "$cfg" core.editor             "${GIT_EDITOR:-true}"
    _git_set "$user" "$cfg" merge.conflictStyle     "${GIT_CONFLICT_STYLE:-zdiff3}"
    # A first push that fails on a missing upstream is a needless round trip.
    _git_set "$user" "$cfg" push.autoSetupRemote    "true"
    _git_set "$user" "$cfg" push.default            "simple"
    _git_set "$user" "$cfg" fetch.prune             "true"
    _git_set "$user" "$cfg" rebase.autoStash        "true"
    _git_set "$user" "$cfg" advice.detachedHead     "false"
    # No pager: a paged command waiting for a keypress hangs a non-interactive
    # caller, and the agent is always non-interactive.
    _git_set "$user" "$cfg" core.pager              "${GIT_PAGER:-cat}"

    if [[ -n ${GIT_SIGNING_KEY:-} ]]; then
        _git_set "$user" "$cfg" user.signingkey "$GIT_SIGNING_KEY"
        _git_set "$user" "$cfg" commit.gpgsign  "true"
    fi
}

# Git refuses to operate inside a repository owned by another account. An agent
# asked to look at a checkout it did not create hits that immediately, and the
# message ("dubious ownership") does not suggest a fix anyone guesses.
_git_safe_directories() {
    local user=$1 cfg=$2 dir IFS=$' \t\n'
    [[ -n ${GIT_SAFE_DIRECTORIES:-} ]] || return 0
    for dir in $GIT_SAFE_DIRECTORIES; do
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] git config --add safe.directory ${dir}"
            continue
        fi
        runuser -u "$user" -- git config --file "$cfg" --get-all safe.directory 2>/dev/null \
            | grep -qxF "$dir" && continue
        runuser -u "$user" -- git config --file "$cfg" --add safe.directory "$dir" ||
            die "could not add ${dir} to safe.directory"
        mark_changed
        log_ok "safe.directory += ${dir}"
    done
}

# Anything the catalogue does not cover: KEY=VALUE pairs, newline-separated.
_git_extra() {
    local user=$1 cfg=$2 line key value
    [[ -n ${GIT_EXTRA_CONFIG:-} ]] || return 0
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z $line || $line == '#'* ]] && continue
        key=${line%%=*}; value=${line#*=}
        _git_set "$user" "$cfg" "${key// /}" "$value"
    done <<<"$GIT_EXTRA_CONFIG"
}

_git_report() {
    local user=$1 cfg=$2 home=${3:-}
    [[ $DRY_RUN == true ]] && return 0
    local name email
    name=$(runuser -u "$user" -- git config --file "$cfg" --get user.name 2>/dev/null || printf '')
    email=$(runuser -u "$user" -- git config --file "$cfg" --get user.email 2>/dev/null || printf '')
    if [[ -n $name && -n $email ]]; then
        log_info "identity       ${name} <${email}>"
    else
        log_warn "no git identity configured for ${user}; commits will fail"
    fi
    _git_report_public_key "$home"
}

# The one part of this that cannot be automated: the public key has to be added
# to the forge by a human. Print it where it cannot be missed, on its own, ready
# to select and copy.
_git_report_public_key() {
    local home=$1 key pub
    [[ -n $home ]] || return 0
    is_true "${GIT_SSH_MANAGE:-false}" || return 0
    # Read from the repository copy: it is the original, and it is readable
    # without becoming the service account.
    local repo_pub="${CREDENTIALS_DIR:-${SCRIPT_DIR}/config/credentials}/ssh/id_${GIT_SSH_KEY_TYPE:-ed25519}.pub"
    key=$(git_ssh_key_path "$home")
    pub=$([[ -f $repo_pub ]] && printf '%s' "$repo_pub" || printf '%s' "${key}.pub")

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would print the public key from ${pub}"
        return 0
    fi
    [[ -f $pub ]] || { log_warn "no public key at ${pub}"; return 0; }

    local fp
    fp=$(ssh-keygen -lf "$pub" 2>/dev/null || printf '')

    # Ask the forge before telling the operator to do something. A key that
    # already authenticates needs no call to action, and printing one anyway
    # trains the reader to skip the box — including on the run where it matters.
    local host=${GIT_SSH_HOSTS%% *} greeting=""
    if [[ -n $host ]]; then
        greeting=$(runuser -u "${SERVICE_USER:-$(id -un)}" -- \
                   ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                       -o ConnectTimeout=10 -T "git@${host}" 2>&1 | head -1 || printf '')
    fi
    case $greeting in
        *successfully\ authenticated*|*Welcome\ to\ GitLab*)
            log_ok "the key authenticates to ${host}: ${greeting}"
            [[ -n $fp ]] && log_info "key            ${fp}"
            return 0 ;;
    esac

    {
        printf '\n'
        printf '  ┌─ Add this public key to your git forge ────────────────────\n'
        printf '  │  GitHub:  Settings -> SSH and GPG keys -> New SSH key\n'
        printf '  │  GitLab:  Preferences -> SSH Keys\n'
        printf '  └────────────────────────────────────────────────────────────\n\n'
        cat "$pub"
        printf '\n'
        [[ -n $fp ]] && printf '  fingerprint: %s\n\n' "$fp"
        printf '  Until it is added, the agent can read public repositories and\n'
        printf '  nothing else. Verify afterwards with:\n'
        printf '    sudo -u %s -H ssh -T git@%s\n\n' "${SERVICE_USER:-hermes}" "$host"
    } >&2
}

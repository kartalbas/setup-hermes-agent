# shellcheck shell=bash
#
# Deploying credential files from the repository onto the host.
#
# The principle this serves: everything is prepared in the repository before the
# first run, and nothing is produced by hand on the target afterwards. Values go
# in the secrets file; whole files — keys, tokens, sessions — go here.
#
# It matters beyond tidiness. A credential created on the host exists only
# there: it is not in a backup, it is not reproducible, and rebuilding the
# machine loses it. A credential deployed from the repository survives the host.

credentials_apply() {
    local dir="${CREDENTIALS_DIR:-${SCRIPT_DIR}/config/credentials}"
    [[ -d $dir ]] || { log_skip "no credential directory at ${dir}"; return 0; }
    [[ -n ${CREDENTIAL_FILES:-} ]] || { log_skip "no CREDENTIAL_FILES declared"; return 0; }

    log_step "Credentials"

    _cred_ensure_ssh_key "$dir"

    local user home
    user=${SERVICE_USER:-$(id -un)}
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $home ]] || { log_warn "cannot determine the home directory of ${user}"; return 0; }

    local line src rel dest mode rest optional count=0 waiting=0
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z $line || $line == '#'* ]] && continue

        # "relative/source -> ~/destination MODE [optional]"
        rel=${line%%->*};  rel=${rel%"${rel##*[![:space:]]}"}
        rest=${line#*->};  rest=${rest#"${rest%%[![:space:]]*}"}
        dest=${rest%% *}
        rest=${rest#"$dest"}; rest=${rest#"${rest%%[![:space:]]*}"}
        mode=${rest%% *}
        [[ $mode =~ ^[0-7]{3,4}$ ]] || mode=0600
        optional=false
        [[ $rest == *optional* ]] && optional=true
        dest=${dest/#\~/$home}

        src="${dir}/${rel}"
        if [[ ! -f $src ]]; then
            if [[ $optional == true ]]; then
                # Declared optional: its absence is a documented state, not a
                # silent skip. Say so, and say what it means.
                log_info "not supplied: ${rel} — the CLI will need a sign-in on the host instead"
                waiting=$(( waiting + 1 ))
                continue
            fi
            if [[ $DRY_RUN == true ]]; then
                # A generated credential does not exist yet during a dry run,
                # because generating it is itself a change.
                log_info "[dry-run] ${rel} would be generated, then deployed to ${dest}"
                continue
            fi
            log_error "required by CREDENTIAL_FILES but not present: ${src}"
            log_error "  provide it, or mark the line optional in config/install.conf"
            die "missing credential file"
        fi

        _cred_deploy "$src" "$dest" "$mode" "$user" && count=$(( count + 1 ))
    done <<<"$CREDENTIAL_FILES"

    log_info "credentials    ${count} deployed${waiting:+, ${waiting} awaiting a sign-in}"
}

# The key is generated HERE, in the repository, not on the host.
#
# A key created on the target exists only on the target: rebuild the machine and
# it is gone, and the forge is left trusting a key nobody holds any more. Born
# in the repository, it survives the host — and it can be registered with the
# forge before the first install, so the agent can push from its first minute
# rather than waiting for someone to notice that it cannot.
_cred_ensure_ssh_key() {
    local dir=$1 type=${GIT_SSH_KEY_TYPE:-ed25519}
    local key="${dir}/ssh/id_${type}"

    is_true "${GIT_SSH_MANAGE:-false}" || return 0
    [[ -f $key ]] && { log_skip "ssh key present in the repository"; return 0; }
    have_cmd ssh-keygen || { log_warn "ssh-keygen unavailable; no key generated"; return 0; }

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] generate ${type} key at ${key}"
        return 0
    fi

    install -d -m 0700 "${dir}/ssh"
    # No passphrase: nothing can type one for an unattended service. The key is
    # protected by file permissions, by the account it is deployed to, and by
    # this directory never being committed.
    ssh-keygen -t "$type" -f "$key" -N "" \
        -C "${GIT_SSH_KEY_COMMENT:-${SERVICE_USER:-hermes}@$(hostname -s)}" >/dev/null || {
        log_warn "could not generate an ssh key"
        return 1
    }
    chmod 0600 "$key"; chmod 0644 "${key}.pub"
    mark_changed
    log_ok "generated ${type} key in the repository"
    log_warn "it is new, so the forge does not know it yet — the public half is"
    log_warn "  printed at the end of this run; add it before expecting a push to work"
}

_cred_deploy() {
    local src=$1 dest=$2 mode=$3 user=$4

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] deploy ${src##*/} -> ${dest} (mode ${mode})"
        return 0
    fi

    # Converge rather than copy: an unchanged credential must not be rewritten,
    # because rewriting reports a change and a change restarts the service.
    if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
        local cur; cur=$(stat -c '%a' "$dest" 2>/dev/null || printf '')
        if [[ $cur == "${mode#0}" || $cur == "$mode" ]]; then
            log_skip "unchanged: ${dest}"
            return 0
        fi
    fi

    local parent="${dest%/*}"
    [[ -d $parent ]] || run install -d -m 0700 -o "$user" -g "$user" "$parent"

    run install -m "$mode" -o "$user" -g "$user" "$src" "$dest"
    mark_changed
    log_ok "deployed ${dest}"
}

# shellcheck shell=bash
#
# This host's settings in your own private config repository — a command, not
# a module of the install run:
#
#   sudo ./install.sh configs        pull it, put this host's files in place
#   sudo ./install.sh configs save   pull, copy them back, commit, push
#
# The files are the ones git keeps out of this repository and the run reads
# (configs_wanted): the site config, the secrets, the credentials. They are
# kept there as they are, unencrypted — the repository must stay private.
# CONFIGS_REPO=OWNER/NAME is cloned as the invoking user — git never runs as
# root — to ~/repos/<owner in lower case>/<name>; this host's files live in
# setup-hermes-agent/hosts/<CONFIGS_HOST>/ (default: the short host name), each
# under its path in this checkout. Only that folder is ever staged, so
# anything else changed in the clone stays out of the commit.

readonly CONFIGS_PROJECT=setup-hermes-agent

# ---------------------------------------------------------------------------
# Which files, and how they are put back
# ---------------------------------------------------------------------------

# configs_wanted PATH — is this path (relative to the checkout) one of this
# host's settings? Git has to ignore it as well (configs_local_files, and
# _configs_apply before it writes).
configs_wanted() {
    case $1 in
        temp/*|bot/build/*|.state/*|None/*) return 1 ;;   # scratch, generated, runtime
        config/credentials/README.md)       return 1 ;;
        config/credentials/*)               return 0 ;;
        config/*/*)                         return 1 ;;
        config/*.conf)                      return 0 ;;
        *.secrets|secrets.env|*/secrets.env) return 0 ;;
    esac
    return 1
}

# configs_mode PATH — its mode in the checkout: secrets and keys 0600, the rest
# 0644 (a sourced config must not be writable by group or others either way).
configs_mode() {
    case $1 in
        *.pub)                                                      printf '0644' ;;
        config/credentials/*|config/*secret*|*.secrets|*secrets.env) printf '0600' ;;
        *)                                                          printf '0644' ;;
    esac
}

# ---------------------------------------------------------------------------
# The invoking user, who owns the clone and runs git
# ---------------------------------------------------------------------------
configs_user() { printf '%s' "${SUDO_USER:-$(id -un)}"; }

configs_home() {
    if [[ -n ${SUDO_USER:-} ]]; then getent passwd "$SUDO_USER" | cut -d: -f6
    else printf '%s' "$HOME"; fi
}

configs_as_user() {               # configs_as_user CMD... — as the invoking user
    local user; user=$(configs_user)
    if [[ $(id -un) == "$user" ]]; then "$@"
    else sudo -u "$user" -H -- "$@"; fi
}

configs_remote_url() { printf 'https://github.com/%s.git' "$CONFIGS_REPO"; }

configs_clone_dir() {
    local owner=${CONFIGS_REPO%%/*}
    printf '%s/repos/%s/%s' "$(configs_home)" "${owner,,}" "${CONFIGS_REPO#*/}"
}

configs_host() { printf '%s' "${CONFIGS_HOST:-$(hostname -s)}"; }

# The settings this checkout holds now, relative to it, one per line.
configs_local_files() {
    local path
    configs_as_user git -C "$SCRIPT_DIR" ls-files --others --ignored --exclude-standard -z |
        while IFS= read -r -d '' path; do
            if configs_wanted "$path"; then printf '%s\n' "$path"; fi
        done
    return 0
}

# ---------------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------------

# The configuration as far as it exists: on a new host there is none yet, and
# `configs` is what brings it. CONFIGS_REPO and CONFIGS_HOST from the
# environment outrank the file.
configs_command() {               # configs_command apply|save
    local repo_env=${CONFIGS_REPO:-} host_env=${CONFIGS_HOST:-} file
    config_defaults
    for file in "$ACCOUNT_FILE" "$INSTALL_FILE" "$CONFIG_FILE" "$CHANNELS_FILE"; do
        [[ -f $file ]] && config_load "$file"
    done
    config_defaults
    [[ -n $repo_env ]] && CONFIGS_REPO=$repo_env
    [[ -n $host_env ]] && CONFIGS_HOST=$host_env
    configs_run "$1"
}

configs_run() {                   # configs_run apply|save
    local mode=$1 dir host sub
    [[ $CONFIGS_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
        die "no config repository: set CONFIGS_REPO=OWNER/NAME in config/hermes.conf, or run: sudo CONFIGS_REPO=OWNER/NAME ./install.sh configs"
    [[ $(configs_user) != root ]] ||
        die "run it with sudo from your own account: the repository is cloned and pushed as you, never as root"
    host=$(configs_host)
    [[ $host =~ ^[A-Za-z0-9_.-]+$ ]] || die "CONFIGS_HOST is not a folder name: '${host}'"
    dir=$(configs_clone_dir)
    sub="${dir}/${CONFIGS_PROJECT}/hosts/${host}"
    log_step "This host's settings: ${CONFIGS_REPO}, ${CONFIGS_PROJECT}/hosts/${host}"

    if [[ ! -d ${dir}/.git ]]; then
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] clone ${CONFIGS_REPO} to ${dir}"
        else
            configs_as_user mkdir -p "$(dirname "$dir")"
            configs_as_user git clone -q "$(configs_remote_url)" "$dir" ||
                die "could not clone ${CONFIGS_REPO} (is $(configs_user) signed in to GitHub?)"
        fi
    fi
    case $mode in
        apply)
            if [[ $DRY_RUN != true ]]; then
                configs_as_user git -C "$dir" pull -q --ff-only ||
                    log_warn "${CONFIGS_REPO} not updated (offline, or local changes) — using it as it is"
            fi
            _configs_apply "$sub" "$host" ;;
        save)
            if [[ $DRY_RUN != true ]]; then
                configs_as_user git -C "$dir" pull -q --ff-only ||
                    die "${CONFIGS_REPO} cannot be brought up to date in ${dir}: settle that first, then save again"
            fi
            _configs_save "$dir" "$sub" "$host" ;;
        *) die "configs [save]" ;;
    esac
}

_configs_apply() {                # _configs_apply HOSTDIR HOST
    local sub=$1 host=$2 src path dst mode parent count=0
    local -a own=()
    if [[ ! -d $sub ]]; then
        [[ $DRY_RUN == true ]] && { log_info "[dry-run] nothing to show: no clone yet"; return 0; }
        die "nothing is saved for ${host} in ${CONFIGS_REPO} yet: sudo ./install.sh configs save on that host"
    fi
    # The checkout's owner keeps owning its settings, also under sudo. An array:
    # IFS is newline/tab in this program, so "-o u -g g" in one word would
    # reach install as a single argument.
    (( EUID == 0 )) && own=(-o "$(stat -c '%U' "$SCRIPT_DIR")" -g "$(stat -c '%G' "$SCRIPT_DIR")")
    while IFS= read -r -d '' src; do
        path=${src#"$sub"/}
        # A setting of this checkout that git ignores, or nothing: whatever the
        # config repository carries, it never lands on code git tracks.
        if ! configs_wanted "$path" || ! configs_as_user git -C "$SCRIPT_DIR" check-ignore -q -- "$path"; then
            log_warn "not a setting of this checkout, left alone: ${path}"
            continue
        fi
        dst="${SCRIPT_DIR}/${path}" mode=$(configs_mode "$path")
        if [[ -f $dst ]] && cmp -s "$src" "$dst" && [[ $(stat -c '%a' "$dst") == "${mode#0}" ]]; then
            log_skip "unchanged: ${path}"
            continue
        fi
        parent=$(dirname "$dst")
        if [[ ! -d $parent ]]; then
            run install -d -m 0700 ${own[@]+"${own[@]}"} "$parent"
        fi
        run install -m "$mode" ${own[@]+"${own[@]}"} "$src" "$dst"
        log_ok "${path} (${mode})"
        count=$(( count + 1 ))
    done < <(find "$sub" -type f -print0 | sort -z)
    (( count )) || log_skip "every setting already in place"
}

_configs_save() {                 # _configs_save CLONE HOSTDIR HOST
    local dir=$1 sub=$2 host=$3 path dst count=0
    local folder="${CONFIGS_PROJECT}/hosts/${host}"
    _configs_remember "$host"
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        dst="${sub}/${path}"
        if [[ -f $dst ]] && cmp -s "${SCRIPT_DIR}/${path}" "$dst"; then continue; fi
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] copy ${path} to ${folder}/${path}"
        else
            configs_as_user mkdir -p "$(dirname "$dst")"
            configs_as_user install -m 0600 "${SCRIPT_DIR}/${path}" "$dst"
        fi
        count=$(( count + 1 ))
    done < <(configs_local_files)
    [[ $DRY_RUN == true ]] && { log_info "[dry-run] ${count} file(s) would change; commit and push them"; return 0; }
    configs_as_user git -C "$dir" add -A -- "$folder"
    if configs_as_user git -C "$dir" diff --cached --quiet -- "$folder"; then
        log_ok "nothing changed"
        return 0
    fi
    [[ -n $(configs_as_user git -C "$dir" config user.name) && -n $(configs_as_user git -C "$dir" config user.email) ]] ||
        die "git has no identity for $(configs_user): git config --global user.name NAME; git config --global user.email EMAIL"
    configs_as_user git -C "$dir" commit -q -m "${CONFIGS_PROJECT} settings from ${host}" -- "$folder"
    configs_as_user git -C "$dir" push -q || die "could not push to ${CONFIGS_REPO}; the commit waits in ${dir}"
    log_ok "saved to ${CONFIGS_REPO}: ${folder} (${count} file(s) changed)"
}

# The saved configuration names its repository, so the next host that
# restores it knows where it came from.
_configs_remember() {             # _configs_remember HOST
    local host=$1 file=$CONFIG_FILE add=""
    [[ -f $file ]] || return 0
    grep -qE '^[[:space:]]*CONFIGS_REPO=' "$file" || add+="CONFIGS_REPO=\"${CONFIGS_REPO}\"\n"
    if [[ $host != "$(hostname -s)" ]] && ! grep -qE '^[[:space:]]*CONFIGS_HOST=' "$file"; then
        add+="CONFIGS_HOST=\"${host}\"\n"
    fi
    [[ -n $add ]] || return 0
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] note the config repository in ${file}"
        return 0
    fi
    # shellcheck disable=SC2059  # the lines are ours, their \n is meant
    printf "\n# Where configs / configs save keep this host's settings (a private repository).\n${add}" >>"$file"
    log_ok "noted in ${file}: ${add//\\n/ }"
}

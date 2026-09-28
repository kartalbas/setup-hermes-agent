#!/usr/bin/env bats
#
# `configs [save]`: this host's settings in a private config repository —
# which files they are, where they go, with which modes, and git only ever as
# the invoking user. Against a throwaway checkout of this repository's shape
# and a local bare repository standing in for the private one.

setup() {
    load helper
    load_libs
    silence_logs
    export GIT_CONFIG_NOSYSTEM=1
    HOME=$(mktemp -d); export HOME                      # the invoking user's, with an identity
    git config --global user.name "Test Operator"
    git config --global user.email "operator@example.com"
    git config --global init.defaultBranch master
    unset SUDO_USER
    DRY_RUN=false
    checkout
    remote
    CONFIGS_REPO=Owner/configs-private
    CONFIGS_HOST=box1
    CONFIG_FILE="${CK}/config/hermes.conf"
    CLONE="${HOME}/repos/owner/configs-private"
    FOLDER="setup-hermes-agent/hosts/box1"
}

teardown() { rm -rf "$CK" "${REMOTE%/*}" "$HOME"; }

# A checkout of this repository's shape: what git tracks, and the site's own.
checkout() {
    CK=$(mktemp -d)
    cp "$REPO_ROOT/.gitignore" "$CK/"
    mkdir -p "$CK/config/credentials/ssh" "$CK/libs" "$CK/temp" "$CK/bot/build"
    printf 'tracked\n' >"$CK/config/bootstrap.conf"
    printf 'tracked\n' >"$CK/config/install.conf"
    printf 'example\n' >"$CK/config/hermes.conf.example"
    printf 'readme\n' >"$CK/config/credentials/README.md"
    printf 'code\n' >"$CK/libs/10-util.sh"
    git -C "$CK" init -q
    git -C "$CK" add -A
    git -C "$CK" commit -qm base
    printf 'SITE=1\n' >"$CK/config/hermes.conf";                  chmod 0644 "$CK/config/hermes.conf"
    printf 'CHANNELS=1\n' >"$CK/config/channels.conf";            chmod 0644 "$CK/config/channels.conf"
    printf 'TOKEN=secret\n' >"$CK/config/secrets.conf";           chmod 0600 "$CK/config/secrets.conf"
    printf 'private key\n' >"$CK/config/credentials/ssh/id_ed25519"; chmod 0600 "$CK/config/credentials/ssh/id_ed25519"
    printf 'public key\n' >"$CK/config/credentials/ssh/id_ed25519.pub"
    printf 'x\n' >"$CK/site.secrets"
    printf 'x\n' >"$CK/secrets.env"
    # ignored as well, but not settings: a copy, a stray key, scratch, a build
    printf 'copy\n' >"$CK/config/hermes.conf.bak"
    printf 'x\n' >"$CK/stray.pem"
    printf 'x\n' >"$CK/temp/shot.png"
    printf 'x\n' >"$CK/temp/leftover.secrets"
    printf 'x\n' >"$CK/bot/build/app.zip"
    SCRIPT_DIR=$CK
}

# The private repository: bare, with something of its own already in it.
remote() {
    REMOTE=$(mktemp -d)/configs.git
    git init -q --bare "$REMOTE"
    local seed; seed=$(mktemp -d)
    git -C "$seed" init -q
    printf 'mine\n' >"$seed/README.md"
    git -C "$seed" add -A
    git -C "$seed" commit -qm init
    git -C "$seed" push -q "$REMOTE" HEAD:master
    rm -rf "$seed"
    configs_remote_url() { printf '%s' "$REMOTE"; }
}

commits() { git -C "$REMOTE" rev-list --count master; }

@test "the settings are what git keeps out of the checkout and the run reads — no example, tracked, scratch or stray file" {
    [ "$(configs_local_files | sort | tr '\n' ' ')" = "config/channels.conf config/credentials/ssh/id_ed25519 config/credentials/ssh/id_ed25519.pub config/hermes.conf config/secrets.conf secrets.env site.secrets " ]
}

@test "secrets and keys go back 0600, public keys and settings 0644" {
    for p in config/secrets.conf config/site-secrets.conf config/credentials/ssh/id_ed25519 config/credentials/google.token a/b.secrets secrets.env; do
        [ "$(configs_mode "$p")" = 0600 ] || { echo "$p"; false; }
    done
    for p in config/hermes.conf config/channels.conf config/credentials/ssh/id_ed25519.pub; do
        [ "$(configs_mode "$p")" = 0644 ] || { echo "$p"; false; }
    done
    configs_wanted config/credentials/ssh/id_ed25519 && configs_wanted a/b.secrets && configs_wanted config/hermes.conf
    ! configs_wanted config/credentials/README.md && ! configs_wanted config/sub/x.conf && ! configs_wanted temp/x.secrets
    ! configs_wanted libs/10-util.sh && ! configs_wanted config/hermes.conf.bak
}

@test "save puts them under hosts/<host>/, commits once as that host, pushes, and stages nothing else" {
    configs_run save
    [ "$(commits)" -eq 2 ]
    [ "$(git -C "$REMOTE" log -1 --format=%s master)" = "setup-hermes-agent settings from box1" ]
    [ "$(git -C "$REMOTE" ls-tree -r --name-only master -- "$FOLDER" | sort | tr '\n' ' ')" = "${FOLDER}/config/channels.conf ${FOLDER}/config/credentials/ssh/id_ed25519 ${FOLDER}/config/credentials/ssh/id_ed25519.pub ${FOLDER}/config/hermes.conf ${FOLDER}/config/secrets.conf ${FOLDER}/secrets.env ${FOLDER}/site.secrets " ]
    [ "$(git -C "$REMOTE" show "master:${FOLDER}/config/secrets.conf")" = "TOKEN=secret" ]
    # the saved config names its repository and this host's folder
    grep -qx 'CONFIGS_REPO="Owner/configs-private"' "$CK/config/hermes.conf"
    grep -qx 'CONFIGS_HOST="box1"' "$CK/config/hermes.conf"
    # unchanged: nothing to commit, and what else changed in the clone stays out
    printf 'edited\n' >>"${CLONE}/README.md"
    configs_run save
    [ "$(commits)" -eq 2 ]
    # a changed setting: one more commit, with it alone
    printf 'SITE=2\n' >>"$CK/config/hermes.conf"
    configs_run save
    [ "$(commits)" -eq 3 ]
    [ "$(git -C "$REMOTE" show --name-only --format= master)" = "${FOLDER}/config/hermes.conf" ]
    [ "$(git -C "$REMOTE" show master:README.md)" = mine ]
}

@test "configs puts them back with their modes, and never onto a file git tracks" {
    configs_run save
    rm -f "$CK/config/secrets.conf" "$CK/config/credentials/ssh/id_ed25519" "$CK/config/channels.conf"
    rm -rf "$CK/config/credentials/ssh"
    # a config repository that carries more than settings
    mkdir -p "${CLONE}/${FOLDER}/libs"
    printf 'replaced\n' >"${CLONE}/${FOLDER}/libs/10-util.sh"
    printf 'replaced\n' >"${CLONE}/${FOLDER}/config/bootstrap.conf"
    configs_run apply
    [ "$(cat "$CK/config/secrets.conf")" = "TOKEN=secret" ] && [ "$(stat -c %a "$CK/config/secrets.conf")" = 600 ]
    [ "$(stat -c %a "$CK/config/credentials/ssh/id_ed25519")" = 600 ]
    [ "$(stat -c %a "$CK/config/credentials/ssh/id_ed25519.pub")" = 644 ]
    [ "$(stat -c %a "$CK/config/credentials/ssh")" = 700 ]
    [ "$(stat -c %a "$CK/config/channels.conf")" = 644 ]
    [ "$(cat "$CK/libs/10-util.sh")" = code ] && [ "$(cat "$CK/config/bootstrap.conf")" = tracked ]
}

@test "a host with nothing saved yet is told where to save it first" {
    CONFIGS_HOST=box2
    bats_run configs_run apply
    [ "$status" -ne 0 ] && [[ $output == *"nothing is saved for box2"*"configs save on that host"* ]]
}

@test "without a git identity, save stops before committing and says how to set it" {
    git config --global --unset user.email
    bats_run configs_run save
    [ "$status" -ne 0 ] && [[ $output == *"git config --global user.email"* ]]
    [ "$(commits)" -eq 1 ]
}

@test "git never runs as root, and the repository has to be OWNER/NAME" {
    SUDO_USER=root
    bats_run configs_run save
    [ "$status" -ne 0 ] && [[ $output == *"never as root"* ]]
    unset SUDO_USER
    CONFIGS_REPO=""
    bats_run configs_run apply
    [ "$status" -ne 0 ] && [[ $output == *"CONFIGS_REPO=OWNER/NAME"* ]]
    CONFIGS_REPO="no-owner"
    bats_run configs_run apply
    [ "$status" -ne 0 ]
}

@test "a dry run clones, copies, commits and notes nothing" {
    DRY_RUN=true
    before=$(cat "$CK/config/hermes.conf")
    configs_run save
    [ ! -e "$CLONE" ] && [ "$(commits)" -eq 1 ] && [ "$(cat "$CK/config/hermes.conf")" = "$before" ]
}

@test "the command comes before any check that needs the configuration, and the repository stays neutral" {
    config_defaults
    [ -z "$CONFIGS_REPO" ] && [ -z "$CONFIGS_HOST" ]
    bats_run env -u CONFIGS_REPO "$REPO_ROOT/install.sh" --dry-run --config /nonexistent/hermes.conf --channels /nonexistent/channels.conf configs
    [ "$status" -ne 0 ] && [[ $output == *"no config repository"* && $output != *"missing configuration"* ]]
    bats_run env CONFIGS_REPO=Owner/configs-private HOME="$HOME" "$REPO_ROOT/install.sh" --dry-run --config /nonexistent/hermes.conf --channels /nonexistent/channels.conf configs save
    [ "$status" -eq 0 ] && [[ $output == *"[dry-run] clone Owner/configs-private"* ]]
    bats_run "$REPO_ROOT/install.sh" save
    [ "$status" -eq 2 ] && [[ $output == *"unexpected argument: save"* ]]
    "$REPO_ROOT/install.sh" --help | grep -q 'configs save'
}

# Outside the checkout: the agent account's home, the modules' state and the
# agent's data directory, all throwaway, with an agent bundle to compare to.
host_side() {
    AGENT_HOME=$(mktemp -d)
    _configs_agent_home() { printf '%s' "$AGENT_HOME"; }
    SERVICE_USER=$(id -un) SERVICE_GROUP=$(id -gn)
    ASSISTANT_STATE_DIR=$(mktemp -d)/assistant MAILPROXY_STATE_DIR=$(mktemp -d)/mailproxy
    HERMES_HOME=$(mktemp -d)/hermes INSTALL_DIR=$(mktemp -d)
    mkdir -p "$ASSISTANT_STATE_DIR" "$MAILPROXY_STATE_DIR" "$INSTALL_DIR/skills/pdf"
    printf 'shipped\n' >"$INSTALL_DIR/skills/pdf/SKILL.md"
    printf 'm365\n' >"$ASSISTANT_STATE_DIR/m365.token"
    printf 'google\n' >"$ASSISTANT_STATE_DIR/google.token"
    : >"$ASSISTANT_STATE_DIR/google.token.lock"
    printf 'relay\n' >"$MAILPROXY_STATE_DIR/emailproxy.config"
    printf 'cert\n' >"$MAILPROXY_STATE_DIR/relay.key"
    mkdir -p "$AGENT_HOME/.gemini/antigravity-cli" "$AGENT_HOME/.config/gh" "$AGENT_HOME/.claude" \
             "$AGENT_HOME/.config/gcloud/configurations"
    printf 'agy\n' >"$AGENT_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
    printf 'gh\n' >"$AGENT_HOME/.config/gh/hosts.yml"
    printf 'claude\n' >"$AGENT_HOME/.claude/.credentials.json"
    printf 'gcloud\n' >"$AGENT_HOME/.config/gcloud/configurations/config_default"
    printf 'shell\n' >"$AGENT_HOME/.bashrc"
    local p="$HERMES_HOME/profiles/secretary"
    mkdir -p "$p/memories" "$p/cron" "$p/skills/pdf" "$p/skills/own/__pycache__"
    printf 'x\n' >"$HERMES_HOME/config.yaml"; printf 'x\n' >"$p/config.yaml"
    printf 'noted\n' >"$p/memories/MEMORY.md"; printf 'user\n' >"$p/memories/USER.md"; : >"$p/memories/MEMORY.md.lock"
    printf '{"jobs": []}\n' >"$p/cron/jobs.json"; printf 'db\n' >"$p/cron/executions.db"
    printf 'changed by the bot\n' >"$p/skills/pdf/SKILL.md"      # a shipped skill the bot changed
    printf 'written by the bot\n' >"$p/skills/own/SKILL.md"
    printf 'cache\n' >"$p/skills/own/__pycache__/x.pyc"
}

@test "outside the checkout: the sign-ins and the bots' own memory, stored by what they are, not where this host has them" {
    host_side
    [ "$(configs_host_files | cut -d'|' -f1 | sort | tr '\n' ' ')" = "hermes/profiles/secretary/cron/jobs.json hermes/profiles/secretary/memories/MEMORY.md hermes/profiles/secretary/memories/USER.md hermes/profiles/secretary/skills/own/SKILL.md hermes/profiles/secretary/skills/pdf/SKILL.md home/.claude/.credentials.json home/.config/gcloud/configurations/config_default home/.config/gh/hosts.yml home/.gemini/antigravity-cli/antigravity-oauth-token state/assistant/google.token state/assistant/m365.token state/mailproxy/emailproxy.config " ]
    configs_run save
    [ "$(git -C "$REMOTE" show "master:${FOLDER}/host/state/assistant/m365.token")" = m365 ]
    [ "$(git -C "$REMOTE" show "master:${FOLDER}/host/hermes/profiles/secretary/skills/own/SKILL.md")" = "written by the bot" ]
    # every stored path says what it is, none where this host keeps it
    git -C "$REMOTE" ls-tree -r --name-only master -- "${FOLDER}/host" | sed "s#^${FOLDER}/host/##" |
        { ! grep -v -E '^(state|home|hermes)/'; } | { ! grep -F -e "$AGENT_HOME" -e "$ASSISTANT_STATE_DIR" -e "$HERMES_HOME"; }
}

@test "configs puts back only what is missing: a sign-in or memory here is the newer, a profile waits for the run, a shipped skill copy is replaced" {
    host_side
    configs_run save
    local p="$HERMES_HOME/profiles/secretary"
    rm -f "$ASSISTANT_STATE_DIR/m365.token" "$AGENT_HOME/.config/gh/hosts.yml" "$p/memories/USER.md"
    rm -rf "$AGENT_HOME/.claude"
    printf 'renewed here\n' >"$ASSISTANT_STATE_DIR/google.token"      # this host's is the newer
    printf 'changed here\n' >"$p/memories/MEMORY.md"
    rm -f "$p/skills/own/SKILL.md"
    printf 'shipped\n' >"$p/skills/pdf/SKILL.md"                  # a new install's copy, as the agent ships it
    # a profile the run has not created yet, with memory saved for it
    mkdir -p "${CLONE}/${FOLDER}/host/hermes/profiles/news/memories"
    printf 'news\n' >"${CLONE}/${FOLDER}/host/hermes/profiles/news/memories/MEMORY.md"
    configs_run apply
    [ "$(cat "$ASSISTANT_STATE_DIR/m365.token")" = m365 ] && [ "$(stat -c %a "$ASSISTANT_STATE_DIR/m365.token")" = 600 ]
    [ "$(cat "$AGENT_HOME/.config/gh/hosts.yml")" = gh ]
    [ "$(cat "$AGENT_HOME/.claude/.credentials.json")" = claude ] && [ "$(stat -c %a "$AGENT_HOME/.claude")" = 700 ]
    [ "$(cat "$ASSISTANT_STATE_DIR/google.token")" = "renewed here" ]
    [ "$(cat "$p/memories/MEMORY.md")" = "changed here" ] && [ "$(cat "$p/memories/USER.md")" = user ]
    [ "$(cat "$p/skills/own/SKILL.md")" = "written by the bot" ]
    [ "$(cat "$p/skills/pdf/SKILL.md")" = "changed by the bot" ]    # the shipped copy gave way
    [ ! -e "$HERMES_HOME/profiles/news" ]                            # never made ahead of the run
    # a skill changed on this host since is its own, and stays
    printf 'changed here\n' >"$p/skills/pdf/SKILL.md"
    configs_run apply
    [ "$(cat "$p/skills/pdf/SKILL.md")" = "changed here" ]
}

@test "a config repository cannot put a file anywhere, and an account that does not exist yet waits" {
    host_side
    configs_run save
    local h="${CLONE}/${FOLDER}/host"
    mkdir -p "$h/home" "$h/state/assistant" "$h/elsewhere"
    printf 'evil\n' >"$h/home/.bashrc"
    printf 'evil\n' >"$h/state/assistant/not-a-token"
    printf 'evil\n' >"$h/elsewhere/file"
    for rel in home/.bashrc state/assistant/not-a-token elsewhere/file "state/assistant/../../x.token" "hermes/profiles/x/../../y/memories/a.md" "home/.config/gcloud/configurations/config_x/y"; do
        ! configs_host_path "$rel" >/dev/null || { echo "accepted: $rel"; false; }
    done
    configs_run apply
    [ "$(cat "$AGENT_HOME/.bashrc")" = shell ] && [ ! -e "$ASSISTANT_STATE_DIR/not-a-token" ]
    _configs_agent_home() { return 1; }
    LOG_LEVEL=warn
    bats_run configs_run apply
    [ "$status" -eq 0 ] && [[ $output == *"does not exist yet"*"bootstrap.sh, then configs again"* ]]
}

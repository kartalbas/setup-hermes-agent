# shellcheck shell=bash
#
# One profile per bot.
#
# A profile is a complete HERMES_HOME of its own — config.yaml, .env, SOUL.md,
# memory, sessions — under ${HERMES_HOME}/profiles/<key>. The agent's code is
# shared; the identity is not. The persona comes from bot/roles/<role>.md and is
# written as the profile's SOUL.md on every run, so the repository stays the
# only place a bot's character is defined.
#
# Order: after `hermes` (the code and the default profile exist), before
# `service` (the units point at the profiles).

profiles_apply() {
    (( $(bot_count) > 0 )) || { log_skip "no bots configured; single default profile"; return 0; }
    log_step "Bot profiles"
    local key
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"
        _profile_ensure
        _profile_soul
        _profile_workdir
        bot_context_end
    done < <(bots)
}

# Created by the agent's own CLI, cloned from the default profile so the
# providers, policies and everything the earlier modules configured there are
# the starting point. Cloning happens once; afterwards each profile is
# converged by the modules directly.
_profile_ensure() {
    if [[ -f ${BOT_HOME}/config.yaml ]]; then
        log_skip "profile ${BOT_KEY} at ${BOT_HOME}"
        return 0
    fi
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] create profile ${BOT_KEY} (clone of the default) at ${BOT_HOME}"
        return 0
    fi
    # The CLI is run against the DEFAULT home here — it creates the profile
    # under it. bot_context has pointed HERMES_CONFIG_HOME at the (not yet
    # existing) profile, so step out for this one call.
    local saved=$HERMES_CONFIG_HOME
    HERMES_CONFIG_HOME=$HERMES_HOME
    hermes_cli profile create "$BOT_KEY" --clone --no-alias \
        --description "$(head -n 1 "$(bot_role_file "$BOT_KEY")" | sed 's/^# *//')" ||
        die "could not create profile ${BOT_KEY}"
    HERMES_CONFIG_HOME=$saved
    [[ -f ${BOT_HOME}/config.yaml ]] || die "profile ${BOT_KEY} was created but ${BOT_HOME}/config.yaml is missing"
    # The clone carries the default profile's channels — its Teams port, its
    # mailbox. Switched off here so the bot's first start is quiet; the channels
    # module then configures exactly what this bot declares.
    local ch
    for ch in telegram whatsapp teams email; do _channel_disable "$ch"; done
    mark_changed
    log_ok "profile ${BOT_KEY} created at ${BOT_HOME}"
}

# SOUL.md is the agent's primary identity: when it exists, the vendor's own
# "You are Hermes Agent" line is not used. The role file describes the job; the
# name comes from configuration, so it is put first here — with the
# instruction not to call itself by the vendor's name, which a second built-in
# hint ("You run on Hermes Agent") would otherwise invite.
# The bot's scratch space: the terminal's working directory and TMPDIR both
# point here (channels and service modules), so whatever a bot writes for
# itself lands in one place — never in the account's home, never in /tmp —
# and a tmpfiles rule (host module) removes it after two days.
_profile_workdir() {
    ensure_dir "${BOT_HOME}/work" 0750 "${SERVICE_USER}:${SERVICE_GROUP}"
    ensure_dir "${BOT_HOME}/work/tmp" 0750 "${SERVICE_USER}:${SERVICE_GROUP}"
}

profile_soul_text() {          # profile_soul_text ROLE_FILE -> the SOUL.md content
    local role=$1
    cat <<EOF
# ${BOT_DISPLAY_NAME}

Your name is **${BOT_DISPLAY_NAME}**. When asked who you are, say so — never call
yourself "Hermes" or name the software you run on; that is an implementation
detail the operator does not want to see. You are one of the operator's private
assistant bots; everything you produce (names, subjects, files) is in English
unless the operator writes it or asks for another language, and you answer in
the operator's language — in German with the informal "du", never "Sie".

Scratch files — anything you generate on this machine on the way to a result —
go into your working directory (the directory you start in, \`work/\` in your
profile), never into the account's home directory and never into /tmp. Hand
results to the operator through the tools (OneDrive, mail, chat), then remove
what you created; the working directory is emptied of old files anyway.

EOF
    # The role body without its own title line.
    sed '1{/^# /d}' "$role" | sed '1{/^$/d}'
}

_profile_soul() {
    local role; role=$(bot_role_file "$BOT_KEY")
    [[ -f $role ]] || die "bot ${BOT_KEY}: role file ${role} is missing"
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write ${BOT_HOME}/SOUL.md (name ${BOT_DISPLAY_NAME} + ${role#"$SCRIPT_DIR"/})"
        return 0
    fi
    local before=$CHANGE_COUNT
    write_file "${BOT_HOME}/SOUL.md" 0644 "${SERVICE_USER}:${SERVICE_GROUP}" <<<"$(profile_soul_text "$role")"
    # A changed persona is read at start-up; restart only when it changed and
    # the unit already exists (on the first run the service module starts it).
    if (( CHANGE_COUNT > before )) && systemctl list-unit-files "${BOT_SERVICE}.service" 2>/dev/null | grep -q "${BOT_SERVICE}"; then
        if module_selected channels; then
            # The channel pass restarts this bot when its configuration changed;
            # one restart carries both. Handed over, not skipped: the end of the
            # run restarts anything still owed.
            restart_later "${BOT_SERVICE}.service"
            log_ok "new persona for ${BOT_SERVICE}; restarts with its channel pass"
        else
            run systemctl restart "${BOT_SERVICE}.service"   # gated: only when SOUL.md changed
            restart_done "${BOT_SERVICE}.service"
            log_ok "restarted ${BOT_SERVICE} for the new persona"
        fi
    fi
}

profiles_uninstall() { return 0; }

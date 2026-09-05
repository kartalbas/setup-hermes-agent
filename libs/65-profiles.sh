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

_profile_soul() {
    local role; role=$(bot_role_file "$BOT_KEY")
    [[ -f $role ]] || die "bot ${BOT_KEY}: role file ${role} is missing"
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] write ${BOT_HOME}/SOUL.md from ${role#"$SCRIPT_DIR"/}"
        return 0
    fi
    write_file "${BOT_HOME}/SOUL.md" 0644 "${SERVICE_USER}:${SERVICE_GROUP}" <<<"$(cat "$role")"
}

profiles_uninstall() { return 0; }

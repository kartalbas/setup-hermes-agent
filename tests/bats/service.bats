#!/usr/bin/env bats
#
# The service module's pure parts: what a bot unit waits for at boot.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
    SERVICE_NAME=agent-gw
}

@test "a bot unit waits for the bridge and the relay only when this installation runs them" {
    AGY_SHIM_ENABLED=false MAILPROXY_ENABLED=false
    [ "$(_service_bot_deps)" = $'After=network-online.target\nWants=network-online.target' ]
    AGY_SHIM_ENABLED=true MAILPROXY_ENABLED=true
    out=$(_service_bot_deps)
    [[ $out == "After=network-online.target agent-gw-bridge.service agent-gw-mailproxy.service"* ]]
    [[ $out == *$'\nWants=network-online.target agent-gw-bridge.service agent-gw-mailproxy.service' ]]
    [[ $out != *Requires* ]]
}

# The bug this pins: service_apply rebinds SERVICE_NAME to each bot's own unit
# name, and bash's dynamic scoping carried that into agyshim_unit_name() and
# mailproxy_unit_name(). Every bot unit was written waiting for
# "<bot>-bridge.service" and "<bot>-mailproxy.service" — units that do not
# exist, because the host runs one bridge and one relay named after the
# installation. systemd treats a Wants= on an unknown unit as satisfied, so
# nothing failed; the bots simply started before the services they need.
@test "a bot unit names the installation's bridge and relay, not one per bot" {
    AGY_SHIM_ENABLED=true MAILPROXY_ENABLED=true
    SHARED_SERVICE_NAME=agent-gw
    SERVICE_NAME=acme-secretary          # as the per-bot loop leaves it
    out=$(_service_bot_deps)
    [[ $out == *agent-gw-bridge.service* && $out == *agent-gw-mailproxy.service* ]]
    [[ $out != *acme-secretary-bridge* && $out != *acme-secretary-mailproxy* ]]
    [ "$(apiproxy_unit_name deepseek)" = agent-gw-balance-deepseek ]
}

@test "without the anchor the shared names follow the installation" {
    unset SHARED_SERVICE_NAME
    [ "$(agyshim_unit_name)" = agent-gw-bridge ]
    [ "$(mailproxy_unit_name)" = agent-gw-mailproxy ]
}

# A shared service is ordered before whatever waits for it. With bots that is
# every bot unit; the default gateway is retired then, so naming it would order
# the bridge against a unit that is never started.
@test "the shared units are ordered before the units that actually run" {
    BOTS=""
    [ "$(service_consumer_units)" = agent-gw.service ]
    BOTS="secretary news" BOT_SERVICE_PREFIX=acme
    [ "$(service_consumer_units)" = "acme-secretary.service acme-news.service" ]
}

@test "the drop-in bounds the start timeout for a cold boot" {
    out=$(_service_dropin_content)
    [[ $out == *'TimeoutStartSec=300'* ]]
    SERVICE_START_TIMEOUT=120
    [[ $(_service_dropin_content) == *'TimeoutStartSec=120'* ]]
}

@test "a bot unit sends the tools' temporary files into the profile's work directory" {
    BOT_HOME=/home/x/.hermes/profiles/b
    out=$(_service_dropin_content)                      # the drop-in stays free of it: the unit itself carries TMPDIR
    [[ $out != *TMPDIR* ]]
    grep -q 'Environment="TMPDIR=${BOT_HOME}/work/tmp"' "$REPO_ROOT/libs/70-service.sh"
}

@test "the tmpfiles rules age out the bots' scratch and the assistants' download folders" {
    HERMES_HOME=/home/x/.hermes
    out=$(host_tmpfiles_text)
    [[ $out == *'e /home/x/.hermes/profiles/*/work - - - 2d'* && $out == *'e /tmp/onedrive-* - - - 1d'* && $out == *'e /tmp/share-* - - - 1d'* ]]
    [[ $out != *'R '* ]]                                 # age-based cleaning only, nothing unconditional
}

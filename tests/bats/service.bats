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

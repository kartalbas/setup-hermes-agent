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

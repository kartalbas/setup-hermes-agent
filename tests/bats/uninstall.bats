#!/usr/bin/env bats
#
# Teardown, checked structurally.
#
# The failure this guards against has no symptom: a module grows an uninstall
# function, nobody adds the call, and `install.sh --uninstall` reports success
# while leaving a unit, a virtual environment or a CA anchor behind. Three were
# orphaned that way at once (the balance proxies, the ops applier, and the mail
# relay, which had no teardown at all). So the rule is mechanical — every
# module's teardown is called — and this is the test that keeps it true.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
}

body_of_uninstall_apply() {
    declare -f uninstall_apply
}

@test "every module teardown defined in libs/ is called by uninstall_apply" {
    local fn body missing=()
    body=$(body_of_uninstall_apply)
    while IFS= read -r fn; do
        [[ -n $fn ]] || continue
        grep -qw -- "$fn" <<<"$body" || missing+=("$fn")
    done < <(grep -hoE '^[a-z_]+_uninstall\(\)' "$REPO_ROOT"/libs/[0-9][0-9]-*.sh |
             sed 's/()$//' | grep -v '^_' | sort -u)
    [ "${#missing[@]}" -eq 0 ] || {
        printf 'not called by uninstall_apply: %s\n' "${missing[*]}" >&2
        false
    }
}

@test "the applier is retired first, before anything it could reinstall" {
    local body; body=$(body_of_uninstall_apply)
    local ops services
    ops=$(grep -n 'ops_uninstall' <<<"$body" | head -n1 | cut -d: -f1)
    services=$(grep -n '_uninstall_services' <<<"$body" | head -n1 | cut -d: -f1)
    [ -n "$ops" ] && [ -n "$services" ] && [ "$ops" -lt "$services" ]
}

@test "the relay's teardown takes the unit, the venv and the certificate it planted" {
    local src="$REPO_ROOT/libs/55-mailproxy.sh" body
    body=$(sed -n '/^mailproxy_uninstall()/,/^}/p' "$src")
    [[ $body == *'MAILPROXY_VENV'* ]]
    [[ $body == *'/usr/local/share/ca-certificates/hermes-mail-relay.crt'* ]]
    [[ $body == *'update-ca-certificates'* ]]
}

@test "the relay keeps its refresh token unless --purge is given" {
    local body guard removal
    body=$(sed -n '/^mailproxy_uninstall()/,/^}/p' "$REPO_ROOT/libs/55-mailproxy.sh")
    # Every removal of the state directory sits behind the purge guard: a
    # refresh token costs an interactive sign-in to replace, so an uninstall
    # that is only a reinstall must not take it.
    guard=$(grep -n 'DO_PURGE == true' <<<"$body" | head -n1 | cut -d: -f1)
    [ -n "$guard" ]
    while IFS= read -r removal; do
        [ -n "$removal" ] && [ "$removal" -gt "$guard" ]
    done < <(grep -n 'rm -rf "\$MAILPROXY_STATE_DIR"' <<<"$body" | cut -d: -f1)
}

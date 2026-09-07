#!/usr/bin/env bats
#
# install.sh's command line: module selection and the module list.

setup() {
    load helper
    REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)
}

@test "--list-modules prints the modules in run order, preflight first" {
    run "$REPO_ROOT/install.sh" --list-modules
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = preflight ]
    [[ "$output" == *channels* && "$output" == *backup* ]]
}

@test "an unknown module name is refused with the list of modules" {
    run "$REPO_ROOT/install.sh" --dry-run --only nosuchmodule --config "$REPO_ROOT/config/hermes.conf.example" --channels "$REPO_ROOT/config/channels.conf.example"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown module 'nosuchmodule'"* ]]
}

@test "--only keeps canonical order, always includes preflight; --skip removes all but preflight" {
    # Sourced in a child shell: install.sh sets -e/-u/IFS for itself, and its
    # last line runs main only when executed.
    sel() { bash -c 'source "$1"; die() { printf "%s\n" "$*" >&2; exit 1; }; ONLY_MODULES=$2 SKIP_MODULES=$3 selected_modules | tr "\n" " "' _ "$REPO_ROOT/install.sh" "$1" "$2"; }
    [ "$(sel "channels,host" "")" = "preflight host channels " ]
    out=$(sel "" "preflight,azure")
    [[ $out == "preflight "* && $out != *azure* && $out == *backup* ]]
    run sel "bogus" ""
    [ "$status" -ne 0 ]
}

@test "yaml_get reads dotted keys, bools lower-case, and nothing for absent ones" {
    load_libs; silence_logs
    tmp=$(mktemp -d); printf 'gateway:\n  systemd_watchdog_seconds: 90\n  flag: true\n' >"${tmp}/config.yaml"
    yaml_config_path() { printf '%s/config.yaml' "$tmp"; }
    [ "$(yaml_get gateway.systemd_watchdog_seconds)" = 90 ]
    [ "$(yaml_get gateway.flag)" = true ]
    [ -z "$(yaml_get gateway.absent)" ]
    [ -z "$(yaml_get nothing.at.all)" ]
    rm -rf "$tmp"
}

#!/usr/bin/env bats
#
# Pure helpers from src/00-log.sh and src/10-util.sh.

setup() {
    load helper
    load_libs
    silence_logs
}

# --- architecture detection -------------------------------------------------
#
# An allowlist, not a passthrough: an unrecognised architecture must stop the
# run rather than produce an installation for the wrong platform.

@test "detect_arch maps x86_64 to amd64" {
    uname() { printf 'x86_64'; }
    bats_run detect_arch
    [ "$status" -eq 0 ]
    [ "$output" = "amd64" ]
}

@test "detect_arch maps aarch64 to arm64" {
    uname() { printf 'aarch64'; }
    bats_run detect_arch
    [ "$output" = "arm64" ]
}

@test "detect_arch accepts the alternate spellings" {
    uname() { printf 'amd64'; }
    bats_run detect_arch
    [ "$output" = "amd64" ]
    uname() { printf 'arm64'; }
    bats_run detect_arch
    [ "$output" = "arm64" ]
}

@test "detect_arch refuses an unknown architecture" {
    uname() { printf 'riscv64'; }
    bats_run detect_arch
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported architecture"* ]]
}

# --- version comparison -----------------------------------------------------
#
# Compose moved to 5.x, so string matching on "v2." now reports working
# installations as broken. Ordering has to be numeric.

@test "version_ge orders versions numerically, not lexically" {
    bats_run version_ge 10.0.0 9.0.0
    [ "$status" -eq 0 ]
    bats_run version_ge 9.0.0 10.0.0
    [ "$status" -ne 0 ]
}

@test "version_ge treats equal versions as satisfying the requirement" {
    bats_run version_ge 5.5.0 5.5.0
    [ "$status" -eq 0 ]
}

@test "version_ge handles the compose 2.x to 5.x jump" {
    bats_run version_ge 5.5.0 2.40.3
    [ "$status" -eq 0 ]
}

# --- boolean parsing --------------------------------------------------------

@test "is_true accepts the spellings people write in config files" {
    for value in true yes on 1 TRUE Yes ON; do
        bats_run is_true "$value"
        [ "$status" -eq 0 ] || fail "is_true rejected '$value'"
    done
}

@test "is_true rejects everything else, including empty" {
    for value in false no off 0 "" maybe; do
        bats_run is_true "$value"
        [ "$status" -ne 0 ] || fail "is_true accepted '$value'"
    done
}

# --- join_by ----------------------------------------------------------------

@test "join_by joins with the separator and does not leak IFS" {
    IFS=$'\n\t'
    bats_run join_by ', ' one two three
    [ "$output" = "one, two, three" ]
}

@test "join_by returns empty for no items" {
    bats_run join_by ','
    [ "$output" = "" ]
}

# --- redaction --------------------------------------------------------------
#
# Log lines are the most likely place for a credential to escape, so redaction
# is applied centrally rather than at each call site.

@test "log_redact masks a registered secret anywhere in the line" {
    log_redact_register "s3cret-value-here"
    bats_run log_redact "connecting with s3cret-value-here now"
    [ "$output" = "connecting with <redacted> now" ]
}

@test "log_redact ignores short values so ordinary text survives" {
    log_redact_register "abc"
    bats_run log_redact "abc appears here"
    [ "$output" = "abc appears here" ]
}

@test "log_redact masks every occurrence" {
    log_redact_register "tok-abcdefghij"
    bats_run log_redact "tok-abcdefghij and tok-abcdefghij"
    [ "$output" = "<redacted> and <redacted>" ]
}

@test "log_redact passes through text with nothing registered" {
    bats_run log_redact "nothing to hide"
    [ "$output" = "nothing to hide" ]
}

# --- dry-run discipline -----------------------------------------------------
#
# Every mutation is routed through run(). If that stops holding, --dry-run
# silently starts changing things.

@test "run executes the command when DRY_RUN is false" {
    DRY_RUN=false
    bats_run run printf 'executed'
    [ "$output" = "executed" ]
}

@test "run does not execute the command when DRY_RUN is true" {
    DRY_RUN=true
    local marker="${BATS_TEST_TMPDIR}/should-not-exist"
    bats_run run touch "$marker"
    [ "$status" -eq 0 ]
    [ ! -e "$marker" ]
}

@test "run_sh does not execute when DRY_RUN is true" {
    DRY_RUN=true
    local marker="${BATS_TEST_TMPDIR}/also-not"
    bats_run run_sh "touch '$marker'"
    [ ! -e "$marker" ]
}

# --- write_file -------------------------------------------------------------
#
# Convergence: an unchanged re-run must not rewrite the file, because a rewrite
# reports a change and a change triggers a service restart.

@test "write_file creates the file with the requested mode" {
    DRY_RUN=false
    local target="${BATS_TEST_TMPDIR}/created"
    write_file "$target" 0640 <<<"hello"
    [ -f "$target" ]
    [ "$(stat -c '%a' "$target")" = "640" ]
    [ "$(cat "$target")" = "hello" ]
}

@test "write_file leaves identical content untouched and reports no change" {
    DRY_RUN=false
    local target="${BATS_TEST_TMPDIR}/idempotent"
    write_file "$target" 0644 <<<"same"
    CHANGED=false
    write_file "$target" 0644 <<<"same"
    [ "$CHANGED" = "false" ]
}

@test "write_file replaces differing content and reports the change" {
    DRY_RUN=false
    local target="${BATS_TEST_TMPDIR}/changed"
    write_file "$target" 0644 <<<"before"
    CHANGED=false
    write_file "$target" 0644 <<<"after"
    [ "$CHANGED" = "true" ]
    [ "$(cat "$target")" = "after" ]
}

# Regression guard, not a wish: piping into write_file runs it in a subshell,
# where the change flag it sets is discarded. Production code once did exactly
# this, and the visible consequence was a rewritten config that never triggered
# a service restart. Callers must use a here-string or heredoc.
@test "write_file through a pipe cannot report a change — callers must not pipe" {
    DRY_RUN=false
    local target="${BATS_TEST_TMPDIR}/piped"
    printf 'first\n' | write_file "$target" 0644
    CHANGED=false
    printf 'second\n' | write_file "$target" 0644
    [ "$(cat "$target")" = "second" ]     # the write happens
    [ "$CHANGED" = "false" ]              # but the signal is lost in the subshell
}

# The invariant that guard protects.
@test "no library pipes into write_file or yaml_merge" {
    bats_run grep -rnE '\| *(write_file|yaml_merge)' "${REPO_ROOT}/libs"
    [ "$status" -ne 0 ]
}

# --- distro codename --------------------------------------------------------
#
# Derivatives report their own codename but keep the upstream one in
# UBUNTU_CODENAME, and package repositories only know the latter.

@test "distro_codename prefers the upstream codename over the derivative one" {
    os_release_value() {
        case $1 in
            UBUNTU_CODENAME) printf 'noble' ;;
            VERSION_CODENAME) printf 'xia' ;;
        esac
    }
    bats_run distro_codename
    [ "$output" = "noble" ]
}

@test "distro_codename falls back when there is no upstream codename" {
    os_release_value() {
        case $1 in
            UBUNTU_CODENAME) return 1 ;;
            VERSION_CODENAME) printf 'trixie' ;;
        esac
    }
    bats_run distro_codename
    [ "$output" = "trixie" ]
}

# The config contract allows a whitespace-separated list to be wrapped across
# lines, and install.sh sets IFS=$'\n\t' globally — so a split site that sets
# IFS=' ' keeps the newline inside the token. That produced a token consisting
# of a bare newline and an "invalid variable name" abort in the devtools module.
@test "a wrapped list splits into the same fields as a flat one" {
    local flat="alpha beta gamma"
    local wrapped=$'\n  alpha beta\n  gamma\n'
    local -a a=() b=()
    local IFS=$' \t\n'
    # shellcheck disable=SC2206
    a=( $flat ); b=( $wrapped )
    [ "${#a[@]}" -eq 3 ]
    [ "${#b[@]}" -eq 3 ]
    [ "${a[*]}" = "${b[*]}" ]
}

@test "no split site narrows IFS to spaces only" {
    local offenders
    offenders=$(grep -rn "IFS=' '" "${BATS_TEST_DIRNAME}/../../libs" || true)
    [ -z "$offenders" ] || { printf 'IFS=%s drops newlines from wrapped lists:\n%s\n' "' '" "$offenders"; false; }
}

# `exec` with redirections and no command rebinds the shell's own descriptors
# permanently. A 2>/dev/null on such a line silences every subsequent log line,
# and the run continues in the dark — which is exactly what happened: three
# installation failures were diagnosed from host state because their error
# messages had been discarded.
@test "no exec redirection silences the shell's stderr" {
    local offenders
    offenders=$(grep -rnE '^\s*exec\s+\{?[A-Za-z_]*\}?>[^|]*2>\s*/dev/null' \
                     "${BATS_TEST_DIRNAME}/../../libs" \
                     "${BATS_TEST_DIRNAME}/../../install.sh" \
                     "${BATS_TEST_DIRNAME}/../../bootstrap.sh" || true)
    [ -z "$offenders" ] || { printf 'exec redirection with 2>/dev/null:\n%s\n' "$offenders"; false; }
}

@test "acquire_lock leaves stderr usable" {
    local out
    # The redirection must be OUTSIDE, on the subshell: a 2>&1 on log_error
    # itself would capture the message even from a shell whose stderr had been
    # rebound to /dev/null, and the test would pass against the bug.
    out=$( ( DRY_RUN=false
             acquire_lock "${BATS_TEST_TMPDIR}/test.lock"
             log_error "still visible" ) 2>&1 )
    [[ "$out" == *"still visible"* ]]
}

# curl was pinned to https for every request. The bridge, the relay and the
# dashboard all speak plain http on loopback by design, so every check of them
# failed before a packet was sent — and the caller reported a running service
# as dead, with an empty journal excerpt as evidence.
@test "loopback http is allowed; anything else stays https-only" {
    [ "$(_curl_protocols http://127.0.0.1:8787/v1/models)" = "=http,https" ]
    [ "$(_curl_protocols http://localhost:9119/)"          = "=http,https" ]
    [ "$(_curl_protocols 'http://[::1]:8787/v1')"          = "=http,https" ]
    [ "$(_curl_protocols http://127.9.9.9:80/x)"           = "=http,https" ]
    [ "$(_curl_protocols http://example.com/x)"            = "=https" ]
    [ "$(_curl_protocols http://192.0.2.10/dash)"          = "=https" ]
    # Private ranges: the dashboard is published on one of these by design.
    [ "$(_curl_protocols http://10.9.9.9:80/)"             = "=http,https" ]  # agnostic-ok: fixtures for this classifier
    [ "$(_curl_protocols http://192.168.9.9/)"             = "=http,https" ]  # agnostic-ok: fixtures for this classifier
    [ "$(_curl_protocols http://172.16.9.9/)"              = "=http,https" ]  # agnostic-ok: fixtures for this classifier
    [ "$(_curl_protocols http://172.31.9.9/)"              = "=http,https" ]  # agnostic-ok: fixtures for this classifier
    # ...but 172.32 is public space, not part of the private block.
    [ "$(_curl_protocols http://172.32.9.9/)"              = "=https" ]  # agnostic-ok: fixtures for this classifier
    [ "$(_curl_protocols https://example.com/x)"           = "=https" ]
}

# `systemctl restart` followed by an unconditional mark_changed restarts a
# service on EVERY run and then flags the run as changed, which restarts the
# gateway too. Five modules did this. A unit is restarted through converge_unit,
# which restarts only when the calling module changed something.
@test "no module restarts a unit unconditionally" {
    local offenders
    # A restart that is gated by its own module says so on the line, so the
    # exemption is visible where the restart is — like the agnostic-ok marker.
    offenders=$(grep -rnE '^\s*run systemctl restart ' "${BATS_TEST_DIRNAME}/../../libs" \
                | grep -vE 'converge_unit|10-util\.sh|restart_if_changed|# gated' || true)
    # The channels module restarts the gateway deliberately, gated on CHANGED.
    offenders=$(grep -v '80-channels.sh' <<<"$offenders" || true)
    [ -z "$offenders" ] || { printf 'unconditional restarts:\n%s\n' "$offenders"; false; }
}

@test "mark_changed increments the change counter" {
    CHANGED=false; CHANGE_COUNT=0
    mark_changed; mark_changed
    [ "$CHANGED" = true ]
    [ "$CHANGE_COUNT" -eq 2 ]
}

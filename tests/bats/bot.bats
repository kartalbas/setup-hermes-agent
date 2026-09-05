#!/usr/bin/env bats
#
# The bot's version and release mechanics: one version file, semver, a
# changelog that has to say something before a release can happen.

setup() {
    load helper
    load_libs
    silence_logs
    SCRIPT_DIR=$REPO_ROOT
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/bot/release.sh"
}

@test "bot/VERSION is MAJOR.MINOR.PATCH and bot_version returns it" {
    v=$(bot_version)
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    [ "$v" = "$(tr -d '[:space:]' <"${REPO_ROOT}/bot/VERSION")" ]
}

@test "the changelog has a section for the current version" {
    grep -q "^## $(bot_version) — " "${REPO_ROOT}/bot/CHANGELOG.md"
}

@test "release_bump moves the right component" {
    [ "$(release_bump 1.2.3 patch)" = 1.2.4 ]
    [ "$(release_bump 1.2.3 minor)" = 1.3.0 ]
    [ "$(release_bump 1.2.3 major)" = 2.0.0 ]
    [ "$(release_bump 1.2.3 4.0.1)" = 4.0.1 ]
    ! release_bump 1.2.3 banana
}

@test "release_notes returns only the Unreleased body" {
    local f; f=$(mktemp)
    printf '# x\n\n## Unreleased\n\n- one\n- two\n\n## 0.1.0 — 2026-01-01\n\n- old\n' >"$f"
    [ "$(release_notes "$f")" = $'- one\n- two' ]
    rm -f "$f"
}

@test "the teams manifest carries the bot version, not a literal" {
    grep -q '"version": "${BOT_VERSION}"' "${REPO_ROOT}/bot/teams-app/manifest.json.tpl"
}

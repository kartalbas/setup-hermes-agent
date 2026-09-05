#!/usr/bin/env bats
#
# The azure module's pure decisions. The Bot Service's msaAppId is immutable,
# so the only judgement that matters is "does the existing bot carry the
# identity the secrets file names" — and the swapped case, which is what a
# portal wizard with two unlabeled GUID fields produces, has to be recognised
# rather than reported as two unrelated differences.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
}

@test "identical identity is not a mismatch" {
    ! _az_bot_mismatch app-1 tenant-1 app-1 tenant-1
}

@test "a different app id is a mismatch" {
    _az_bot_mismatch app-1 tenant-1 app-2 tenant-1
}

@test "a different tenant is a mismatch" {
    _az_bot_mismatch app-1 tenant-1 app-1 tenant-2
}

@test "swapped app and tenant are a mismatch" {
    _az_bot_mismatch app-1 tenant-1 tenant-1 app-1
}

@test "the bot endpoint is the tunnel hostname plus the ingress path" {
    TUNNEL_HOSTNAME="hermes.example.com"
    TUNNEL_INGRESS_PATH="/api/messages"
    BOT_HOSTNAME=hermes.example.com
    [ "$(az_bot_endpoint)" = "https://hermes.example.com/api/messages" ]
}

@test "the module is skipped entirely when unmanaged" {
    AZURE_MANAGE=false
    bats_run azure_apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"unmanaged"* ]]
}

@test "managing azure without a bot list is refused" {
    AZURE_MANAGE=true BOTS=""
    _az_ensure_cli() { :; }
    _az_use_operator_profile() { :; }
    _az_require_login() { :; }
    bats_run azure_apply
    [ "$status" -ne 0 ]
    [[ $output == *"needs at least one bot"* ]]
}

@test "the bicep template declares a single-tenant bot with a teams channel" {
    local t="${BATS_TEST_DIRNAME}/../../libs/azure/bot.bicep"
    grep -q "msaAppType: 'SingleTenant'" "$t"
    grep -q "name: 'MsTeamsChannel'" "$t"
    grep -q 'param msaAppId string' "$t"
    grep -q 'param msaAppTenantId string' "$t"
    grep -q 'param endpoint string' "$t"
}

@test "the teams app package is built from configuration, deterministically" {
    DRY_RUN=false
    SCRIPT_DIR=$REPO_ROOT
    local tmp; tmp=$(mktemp -d)
    _SECRETS[TEAMS_SECRETARY_CLIENT_ID]="11111111-2222-3333-4444-555555555555"
    TEAMS_APP_DEVELOPER="Tester"
    BOTS="secretary" BOT_PREFIX="Test" TUNNEL_ZONE="example.com" HERMES_HOME="$tmp"
    bot_context secretary
    BOT_DISPLAY_NAME="Test Agent"; BOT_HOSTNAME="agent.example.com"
    bot_teams_package() { printf '%s/build/app.zip' "$tmp"; }
    TEAMS_APP_PACKAGE="${tmp}/build/app.zip"
    SERVICE_USER=""
    bats_run _az_teams_app_package
    [ "$status" -eq 0 ]
    [ -f "$TEAMS_APP_PACKAGE" ]
    python3 - "$TEAMS_APP_PACKAGE" <<'PY'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert sorted(z.namelist()) == ["color.png", "manifest.json", "outline.png"], z.namelist()
m = json.loads(z.read("manifest.json"))
import uuid
assert m["bots"][0]["botId"] == "11111111-2222-3333-4444-555555555555"
assert m["id"] == str(uuid.uuid5(uuid.NAMESPACE_URL, "teams-app/11111111-2222-3333-4444-555555555555")), m["id"]
assert m["id"] != m["bots"][0]["botId"]
assert m["name"]["short"] == "Test Agent"
assert "agent.example.com" in m["validDomains"]
PY
    local first; first=$(sha256sum "$TEAMS_APP_PACKAGE")
    bats_run _az_teams_app_package
    [ "$status" -eq 0 ]
    [[ $output == *unchanged* ]]
    [ "$(sha256sum "$TEAMS_APP_PACKAGE")" = "$first" ]
    rm -rf "$tmp"
}

@test "an empty manifest value fails the package instead of shipping a hole" {
    DRY_RUN=false
    SCRIPT_DIR=$REPO_ROOT
    local tmp; tmp=$(mktemp -d)
    _SECRETS[TEAMS_SECRETARY_CLIENT_ID]="11111111-2222-3333-4444-555555555555"
    TEAMS_APP_DEVELOPER="Tester"
    BOTS="secretary" BOT_PREFIX="Test" TUNNEL_ZONE="example.com" HERMES_HOME="$tmp"
    bot_context secretary
    BOT_HOSTNAME=""
    bot_teams_package() { printf '%s/build/app.zip' "$tmp"; }
    TEAMS_APP_PACKAGE="${tmp}/build/app.zip"
    bats_run _az_teams_app_package
    [ "$status" -ne 0 ]
    [ ! -f "$TEAMS_APP_PACKAGE" ]
    rm -rf "$tmp"
}

@test "a changed package under an unchanged version is refused" {
    DRY_RUN=false
    SCRIPT_DIR=$REPO_ROOT
    local tmp; tmp=$(mktemp -d)
    _SECRETS[TEAMS_SECRETARY_CLIENT_ID]="11111111-2222-3333-4444-555555555555"
    TEAMS_APP_DEVELOPER="Tester"
    BOTS="secretary" BOT_PREFIX="Test" TUNNEL_ZONE="example.com" HERMES_HOME="$tmp"
    bot_context secretary
    BOT_HOSTNAME="agent.example.com"
    bot_teams_package() { printf '%s/build/app.zip' "$tmp"; }
    SERVICE_USER=""
    bats_run _az_teams_app_package
    [ "$status" -eq 0 ]
    BOT_HOSTNAME="other.example.com"          # a real change, same version
    bats_run _az_teams_app_package
    [ "$status" -ne 0 ]
    [[ $output == *"bump it"* ]]
    rm -rf "$tmp"
}

#!/usr/bin/env bats
#
# The assistant module's pure parts: the MCP registration it writes, and the
# scope comparison that decides whether to touch the app registration.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
    ASSISTANT_M365_TIMEZONE="Europe/Zurich"
}

@test "the m365 registration names the venv python, the server script and its env" {
    out=$(_assistant_m365_fragment tenant-1 client-1 agent@example.com)
    [[ $out == *'command: "/var/lib/hermes-assistant/venv/bin/python"'* ]]
    [[ $out == *'args: ["/usr/local/lib/hermes-assistant/m365_assistant.py", "serve"]'* ]]
    [[ $out == *'M365_ACCOUNT: "agent@example.com"'* ]]
    [[ $out == *'M365_TOKEN_FILE: "/var/lib/hermes-assistant/m365.token"'* ]]
    [[ $out == *'M365_SCOPES: "offline_access openid profile'* ]]
    [[ $out == *'enabled: true'* ]]
}

@test "the registration is valid yaml with the env as a map" {
    _assistant_m365_fragment tenant-1 client-1 agent@example.com | python3 -c '
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(0)  # the agent venv has PyYAML; the test host may not
d = yaml.safe_load(sys.stdin)
m = d["mcp_servers"]["m365"]
assert m["env"]["M365_TENANT_ID"] == "tenant-1" and m["timeout"] == 120, m
'
}

@test "missing scopes are the wanted ones not already declared" {
    out=$(_az_missing_scopes "a b c" "b")
    [ "$out" = $'a\nc' ]
    [ -z "$(_az_missing_scopes "a b" "b a extra")" ]
}

@test "an enabled assistant needs an account that looks like a sign-in" {
    ASSISTANT_M365_ENABLED=true ASSISTANT_M365_ACCOUNT=""
    bats_run config_validate
    [ "$status" -ne 0 ]
    ASSISTANT_M365_ACCOUNT="not-an-address"
    bats_run config_validate
    [ "$status" -ne 0 ]
}

@test "the scope comparison splits on spaces even under the installer's IFS" {
    local IFS=$'\n\t'
    out=$(_az_missing_scopes "a b c" "b")
    [ "$out" = $'a\nc' ]
}

@test "the env file quotes its values so the scope list survives being sourced" {
    DRY_RUN=false
    ASSISTANT_STATE_DIR=$(mktemp -d); ASSISTANT_LIB_DIR="${ASSISTANT_STATE_DIR}/lib"; ASSISTANT_VENV="${ASSISTANT_STATE_DIR}/venv"
    SERVICE_USER=$(id -un); SERVICE_GROUP=$(id -gn)
    mkdir -p "$ASSISTANT_LIB_DIR"
    _assistant_m365_wrapper tenant-1 client-1 agent@example.com
    ( set -a; . "${ASSISTANT_STATE_DIR}/m365.env"; [ "$M365_ACCOUNT" = agent@example.com ]; [[ $M365_SCOPES == "offline_access openid"* ]] )
    [ -x "${ASSISTANT_LIB_DIR}/m365ctl" ]
    rm -rf "$ASSISTANT_STATE_DIR"
}

@test "the google registration runs the wrapper, keeping the client secret out of config.yaml" {
    out=$(_assistant_google_fragment)
    [[ $out == *'command: "/usr/local/lib/hermes-assistant/googlectl"'* ]]
    [[ $out == *'args: ["serve"]'* ]]
    [[ $out != *SECRET* ]]
}

@test "a bot may list google only when the google side is enabled" {
    BOTS="secretary" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    ASSISTANT_GOOGLE_ENABLED=false BOT_SECRETARY_MCP="google"
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 1 ]
    ASSISTANT_GOOGLE_ENABLED=true
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 0 ]
}

@test "the github registration runs the wrapper; the token stays in the env file" {
    out=$(_assistant_github_fragment)
    [[ $out == *'command: "/usr/local/lib/hermes-assistant/githubctl"'* ]]
    [[ $out == *'args: ["stdio"]'* ]]
    [[ $out != *TOKEN* ]]
}

@test "a bot may list github only when the github side is enabled" {
    BOTS="github" BOT_PREFIX=X TUNNEL_ZONE=example.com SCRIPT_DIR=$REPO_ROOT
    ASSISTANT_GITHUB_ENABLED=false BOT_GITHUB_MCP="github"
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 1 ]
    ASSISTANT_GITHUB_ENABLED=true
    _invalid=(); _bots_validate; [ "${#_invalid[@]}" -eq 0 ]
}

@test "read mailboxes must be other addresses; the assistant's own is refused" {
    _invalid=(); _check_read_accounts X "you@example.com, other@example.com" agent@example.com
    [ "${#_invalid[@]}" -eq 0 ]
    _invalid=(); _check_read_accounts X "Agent@example.com" agent@example.com
    [ "${#_invalid[@]}" -eq 1 ]
    _invalid=(); _check_read_accounts X "not-an-address" agent@example.com
    [ "${#_invalid[@]}" -eq 1 ]
}

@test "a non-empty read list adds the shared-mail scope once, an empty one adds nothing" {
    unset ASSISTANT_M365_SCOPES ASSISTANT_M365_READ_MAILBOXES
    config_defaults
    [[ $ASSISTANT_M365_SCOPES != *Mail.Read.Shared* ]]
    unset ASSISTANT_M365_SCOPES
    ASSISTANT_M365_READ_MAILBOXES="you@example.com"
    config_defaults; config_defaults
    [ "$(grep -o 'Mail.Read.Shared' <<<"$ASSISTANT_M365_SCOPES" | wc -l)" -eq 1 ]
}

@test "the env files carry the read lists to the servers" {
    ASSISTANT_M365_READ_MAILBOXES="you@example.com"
    out=$(_assistant_m365_env_lines tenant-1 client-1 agent@example.com)
    [[ $out == *$'\nM365_READ_MAILBOXES=you@example.com'* ]]
    secret_get() { printf 'x'; }
    ASSISTANT_GOOGLE_ACCOUNT=agent@gmail.example ASSISTANT_GOOGLE_READ_ACCOUNTS="you@gmail.example"
    out=$(_assistant_google_env_lines)
    [[ $out == *$'\nGOOGLE_READ_ACCOUNTS=you@gmail.example'* ]]
    [[ $out == *'GOOGLE_READ_SCOPES=openid email https://www.googleapis.com/auth/gmail.readonly'* ]]
}

@test "the assistant module never nests sudo: server commands run through runuser" {
    ! grep -qE 'sudo -u "\$SERVICE_USER"' "$REPO_ROOT/libs/62-assistant.sh"
    grep -qE 'runuser -u "\$SERVICE_USER" -- "\$ctl" login' "$REPO_ROOT/libs/62-assistant.sh"
}

@test "the code stamp changes with the installed servers and their env files, and remembers restarts" {
    ASSISTANT_STATE_DIR=$(mktemp -d); ASSISTANT_LIB_DIR="${ASSISTANT_STATE_DIR}/lib"; mkdir -p "$ASSISTANT_LIB_DIR"
    printf 'print(1)\n' >"${ASSISTANT_LIB_DIR}/a.py"
    one=$(_assistant_code_stamp)
    printf 'GOOGLE_READ_ACCOUNTS=x\n' >"${ASSISTANT_STATE_DIR}/google.env"
    two=$(_assistant_code_stamp)
    [ "$one" != "$two" ] && [ "$(_assistant_code_stamp)" = "$two" ]
    _RESTARTED_UNITS=()
    ! unit_restarted_this_run x.service
    _RESTARTED_UNITS+=(x.service)
    unit_restarted_this_run x.service
    rm -rf "$ASSISTANT_STATE_DIR"
}

@test "the worlds setting has one shape, and reaches the server with the root folder" {
    ASSISTANT_M365_ENABLED=true ASSISTANT_M365_ACCOUNT=agent@example.com
    ASSISTANT_M365_WORLDS="Business=_bus,Private=_pri"; bats_run config_validate; [[ "$output" != *ASSISTANT_M365_WORLDS* ]]
    ASSISTANT_M365_WORLDS="Business:_bus"; bats_run config_validate; [ "$status" -ne 0 ]; [[ "$output" == *ASSISTANT_M365_WORLDS* ]]
    ASSISTANT_M365_WORLDS="Business=_bus,Private=_pri" ASSISTANT_M365_ROOT_FOLDER=Secretary
    out=$(_assistant_m365_env_lines t c agent@example.com)
    [[ $out == *$'\nM365_ROOT_FOLDER=Secretary'* && $out == *$'\nM365_WORLDS=Business=_bus,Private=_pri'* ]]
}

@test "the Drive worlds default to the Microsoft 365 values and reach the server" {
    secret_get() { printf 'x'; }
    ASSISTANT_GOOGLE_ACCOUNT=agent@gmail.example ASSISTANT_M365_ROOT_FOLDER=Secretary ASSISTANT_M365_WORLDS="Business=_bus,Private=_pri"
    ASSISTANT_GOOGLE_ROOT_FOLDER="" ASSISTANT_GOOGLE_WORLDS=""
    [ "$(assistant_google_root)" = Secretary ]; [ "$(assistant_google_worlds)" = "Business=_bus,Private=_pri" ]
    out=$(_assistant_google_env_lines)
    [[ $out == *$'\nGOOGLE_ROOT_FOLDER=Secretary'* && $out == *$'\nGOOGLE_WORLDS=Business=_bus,Private=_pri'* ]]
    ASSISTANT_GOOGLE_ROOT_FOLDER=Files ASSISTANT_GOOGLE_WORLDS="Work=_w"
    [ "$(assistant_google_root)" = Files ]; [ "$(assistant_google_worlds)" = "Work=_w" ]
}

@test "the env carries the drop folder name and the default is Inbox" {
    unset ASSISTANT_M365_INBOX; config_defaults
    [ "$ASSISTANT_M365_INBOX" = Inbox ]
    out=$(_assistant_m365_env_lines t c agent@example.com)
    [[ $out == *$'\nM365_INBOX=Inbox'* ]]
}

@test "inboxctl lists only the sides that are installed and signed in, each prefixed" {
    tmp=$(mktemp -d); mkdir -p "${tmp}/lib" "${tmp}/state"
    printf '#!/usr/bin/env bash\n[ "$1" = inbox ] && printf "Secretary/Business/Inbox/a.pdf  (1 bytes)\\n"\n' >"${tmp}/lib/m365ctl"
    printf '#!/usr/bin/env bash\n[ "$1" = inbox ] && printf "Secretary/Private/Inbox/b.jpg  (2 bytes)\\n"\n' >"${tmp}/lib/googlectl"
    chmod 755 "${tmp}"/lib/*ctl; printf 'x' >"${tmp}/state/m365.token"
    out=$(INBOXCTL_LIB="${tmp}/lib" INBOXCTL_STATE="${tmp}/state" bash "$REPO_ROOT/bot/mcp/inboxctl")
    [ "$out" = "onedrive: Secretary/Business/Inbox/a.pdf  (1 bytes)" ]          # no google token: Drive side silent
    printf 'x' >"${tmp}/state/google.token"
    out=$(INBOXCTL_LIB="${tmp}/lib" INBOXCTL_STATE="${tmp}/state" bash "$REPO_ROOT/bot/mcp/inboxctl")
    [[ $out == *"drive: Secretary/Private/Inbox/b.jpg"* ]]
    rm -rf "$tmp"
}

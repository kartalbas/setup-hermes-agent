# shellcheck shell=bash
#
# Azure: the Bot Service that fronts Microsoft Teams, declared in
# src/azure/bot.bicep, plus verification of the two Entra app registrations
# this installation depends on.
#
# What this module does NOT do is create the app registrations. Creating one
# yields a client secret that only this run would ever have seen, and secrets
# in this repository flow one way: from config/secrets.conf to the host. So the
# apps are verified against the IDs the secrets file names, and a mismatch is
# explained rather than papered over.
#
# The operator signs in first (`az login`, a browser step like the CLI and the
# mail relay). Everything after that is this module's job, on every run.

azure_apply() {
    is_true "${AZURE_MANAGE:-false}" || { log_skip "azure unmanaged (AZURE_MANAGE=false)"; return 0; }
    log_step "Azure"
    (( $(bot_count) > 0 )) || die "AZURE_MANAGE=true needs at least one bot in BOTS"

    _az_ensure_cli
    _az_use_operator_profile
    _az_require_login
    _az_ensure_bicep
    _az_verify_apps
    _az_mail_app_scopes
    _az_ensure_group

    local key
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        bot_context "$key"
        log_info "bot            ${BOT_KEY} (${BOT_DISPLAY_NAME}) -> ${BOT_HOSTNAME}"
        _az_bot_app_ensure
        _az_bot_converge
        _az_verify
        _az_teams_app_package
        bot_context_end
    done < <(bots)
}

az_bot_endpoint() { printf 'https://%s%s' "$BOT_HOSTNAME" "$TUNNEL_INGRESS_PATH"; }

# ---------------------------------------------------------------------------
# The bot's Entra app — created here when the secrets file has none for it,
# and the client id and secret written back into the secrets file, which stays
# the single source. An existing app converges its display name (this is how
# "Hermes Teams" became "<prefix> Secretary") and gets a secret if the file
# lacks one. The service principal is what the Bot Service authenticates
# against; the portal creates it silently, so it is ensured here.
# ---------------------------------------------------------------------------
_az_bot_app_ensure() {
    local id_var=$BOT_TEAMS_CLIENT_ID_VAR secret_var=$BOT_TEAMS_CLIENT_SECRET_VAR app_id shown name

    if secret_nonempty "$id_var"; then
        app_id=$(secret_get "$id_var")
        if [[ $DRY_RUN == true ]] && ! az account show >/dev/null 2>&1; then
            log_info "[dry-run] would verify Entra app ${app_id:0:8}… and its display name"
            return 0
        fi
        shown=$(az ad app show --id "$app_id" -o json 2>/dev/null) ||
            die "Entra app ${app_id:0:8}… named by ${id_var} does not exist in this tenant"
        name=$(jq -r '.displayName' <<<"$shown")
        if [[ $name != "$BOT_DISPLAY_NAME" ]]; then
            run az ad app update --id "$app_id" --display-name "$BOT_DISPLAY_NAME" -o none
            mark_changed; log_ok "Entra app renamed: '${name}' -> '${BOT_DISPLAY_NAME}'"
        else
            log_skip "Entra app '${name}' (${app_id:0:8}…)"
        fi
    else
        if [[ $DRY_RUN == true ]]; then
            log_info "[dry-run] would create Entra app '${BOT_DISPLAY_NAME}' and write ${id_var}/${secret_var} to ${SECRETS_FILE}"
            return 0
        fi
        log_info "  creating Entra app '${BOT_DISPLAY_NAME}'"
        app_id=$(az ad app create --display-name "$BOT_DISPLAY_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv) ||
            die "could not create the Entra app for ${BOT_KEY}"
        _secrets_append "$id_var" "$app_id"
        mark_changed; log_ok "Entra app '${BOT_DISPLAY_NAME}' created (${app_id:0:8}…), ${id_var} written"
    fi

    [[ $DRY_RUN == true ]] && return 0
    if ! az ad sp show --id "$app_id" -o none 2>/dev/null; then
        run az ad sp create --id "$app_id" -o none
        mark_changed; log_ok "service principal created for ${app_id:0:8}…"
    fi
    if ! secret_nonempty "$secret_var"; then
        local secret
        log_info "  no ${secret_var} in the secrets file; issuing a client secret"
        secret=$(az ad app credential reset --id "$app_id" --append --display-name "provisioner $(date +%F)" \
                   --years 2 --query password -o tsv) || die "could not issue a client secret for ${BOT_KEY}"
        log_redact_register "$secret"
        _secrets_append "$secret_var" "$secret"
        mark_changed; log_ok "${secret_var} written to the secrets file"
    fi
}

# Append KEY=VALUE to the secrets file and reload. The file keeps its mode.
_secrets_append() {
    local key=$1 value=$2
    [[ -w $SECRETS_FILE ]] || die "cannot write ${SECRETS_FILE}"
    printf '%s=%s\n' "$key" "$value" >>"$SECRETS_FILE"
    secrets_load
}

# ---------------------------------------------------------------------------
# Azure CLI from Microsoft's apt repository — deb822 like cloudflared, not a
# script piped into a root shell.
# ---------------------------------------------------------------------------
_az_ensure_cli() {
    if have_cmd az; then
        log_skip "azure cli present ($(az version --query '"azure-cli"' -o tsv 2>/dev/null || printf '?'))"
        return 0
    fi
    log_info "installing the Azure CLI"
    ensure_dir /etc/apt/keyrings 0755
    run_sh "curl --proto '=https' --tlsv1.2 -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg"
    run chmod a+r /etc/apt/keyrings/microsoft.gpg
    write_file /etc/apt/sources.list.d/azure-cli.sources 0644 <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(distro_codename)
Components: main
Architectures: $(detect_arch)
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF
    DEBIAN_FRONTEND=noninteractive run apt-get update
    DEBIAN_FRONTEND=noninteractive run apt-get install -y azure-cli
    mark_changed
}

# `az login` stores its session under ~/.azure of the account that ran it.
# This run is root under sudo, so root's own profile is empty; use the
# operator's. That is also the right identity: the human who signed in, not
# the machine.
_az_use_operator_profile() {
    local who=${SUDO_USER:-}
    [[ -n $who && $who != root ]] || return 0
    local home; home=$(getent passwd "$who" | cut -d: -f6)
    [[ -d ${home}/.azure ]] || return 0
    export AZURE_CONFIG_DIR="${home}/.azure"
    log_debug "using ${who}'s Azure CLI profile at ${AZURE_CONFIG_DIR}"
}

_az_require_login() {
    export AZURE_CORE_ONLY_SHOW_ERRORS=true
    local tenant_wanted acct tenant_actual
    tenant_wanted=$(secret_require "$AZURE_TENANT_ID_VAR" "the azure module")

    if [[ $DRY_RUN == true ]] && ! acct=$(az account show -o json 2>/dev/null); then
        log_info "[dry-run] would require an Azure CLI login for tenant ${tenant_wanted}"
        return 0
    fi
    if ! acct=$(az account show -o json 2>/dev/null); then
        log_error "the Azure CLI is not signed in (as ${SUDO_USER:-$(id -un)})."
        log_error "  This is a browser step and cannot be scripted. Run, as the account that"
        log_error "  then starts this installer:"
        log_error "    az login --use-device-code --tenant ${tenant_wanted}"
        die "azure: not signed in"
    fi
    tenant_actual=$(jq -r '.tenantId' <<<"$acct")
    if [[ $tenant_actual != "$tenant_wanted" ]]; then
        log_error "signed in to tenant ${tenant_actual}, but the secrets file names ${tenant_wanted}."
        log_error "    az login --use-device-code --tenant ${tenant_wanted}"
        die "azure: wrong tenant"
    fi
    [[ -n $AZURE_SUBSCRIPTION_ID ]] || die "AZURE_SUBSCRIPTION_ID is empty in config/hermes.conf"
    run az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    log_ok "azure cli signed in as $(jq -r '.user.name' <<<"$acct") (tenant ${tenant_actual:0:8}…)"
}

_az_ensure_bicep() {
    if az bicep version >/dev/null 2>&1; then
        log_skip "bicep present ($(az bicep version 2>/dev/null | head -1))"
        return 0
    fi
    log_info "installing the Bicep CLI"
    run az bicep install
    mark_changed
}

# ---------------------------------------------------------------------------
# The two Entra apps. Verified, never created — see the header.
# ---------------------------------------------------------------------------
_az_verify_apps() {
    local mail_id
    mail_id=$(secret_require "$AZURE_MAIL_APP_ID_VAR" "the mail relay")
    [[ $DRY_RUN == true ]] && ! az account show >/dev/null 2>&1 && {
        log_info "[dry-run] would verify the mail app ${mail_id:0:8}…"; return 0; }

    local app
    if ! app=$(az ad app show --id "$mail_id" -o json 2>/dev/null); then
        die "azure: no Entra app registration with client ID ${mail_id} (MAIL_CLIENT_ID)"
    fi
    if [[ $(jq -r '.isFallbackPublicClient' <<<"$app") != true ]]; then
        log_error "mail app $(jq -r '.displayName' <<<"$app") does not allow public client flows."
        log_error "  The device-code sign-in needs it: Authentication -> Allow public client flows -> Yes"
        die "azure: mail app cannot use the device flow"
    fi
    log_ok "mail app      $(jq -r '.displayName' <<<"$app") (${mail_id:0:8}…, public client)"
}

_az_ensure_group() {
    [[ -n $AZURE_RESOURCE_GROUP ]] || die "AZURE_RESOURCE_GROUP is empty in config/hermes.conf"
    [[ $DRY_RUN == true ]] && ! az account show >/dev/null 2>&1 && return 0
    if az group show --name "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
        log_skip "resource group ${AZURE_RESOURCE_GROUP} exists"
    else
        run az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" -o none
        mark_changed
    fi
}

# ---------------------------------------------------------------------------
# The bot. msaAppId is immutable, so this is compare-then-deploy, with an
# explicit switch for the one case that needs a delete.
# ---------------------------------------------------------------------------

# _az_bot_mismatch WANT_APP WANT_TENANT HAVE_APP HAVE_TENANT -> 0 if they differ
_az_bot_mismatch() {
    [[ $1 != "$3" || $2 != "$4" ]]
}

_az_bot_converge() {
    local bot_name=$BOT_AZURE_NAME
    local app tenant endpoint template existing
    if [[ $DRY_RUN == true ]] && ! secret_nonempty "$BOT_TEAMS_CLIENT_ID_VAR"; then
        log_info "[dry-run] would declare bot ${bot_name} once its Entra app exists"
        return 0
    fi
    app=$(secret_require "$BOT_TEAMS_CLIENT_ID_VAR" "the teams bot ${BOT_KEY}")
    tenant=$(secret_require "$AZURE_TENANT_ID_VAR" "the teams bot")
    _az_bot_retire_stale "$app"
    endpoint=$(az_bot_endpoint)
    template="${SCRIPT_DIR}/libs/azure/bot.bicep"
    [[ -f $template ]] || die "missing ${template}"

    if [[ $DRY_RUN == true ]] && ! az account show >/dev/null 2>&1; then
        log_info "[dry-run] would declare bot ${bot_name} -> ${endpoint} (app ${app:0:8}…, tenant ${tenant:0:8}…)"
        return 0
    fi

    existing=$(az resource show --resource-group "$AZURE_RESOURCE_GROUP" \
                 --resource-type Microsoft.BotService/botServices --name "$bot_name" \
                 -o json 2>/dev/null || printf '')
    if [[ -n $existing ]]; then
        local have_app have_tenant
        have_app=$(jq -r '.properties.msaAppId // ""' <<<"$existing")
        have_tenant=$(jq -r '.properties.msaAppTenantId // ""' <<<"$existing")
        if _az_bot_mismatch "$app" "$tenant" "$have_app" "$have_tenant"; then
            # Prefixes, not full GUIDs: every value from the secrets file is
            # redacted in the log, and "has app <redacted>" explains nothing.
            log_error "bot ${bot_name} exists with a different identity:"
            log_error "    has   app ${have_app:0:8}…  tenant ${have_tenant:0:8}…"
            log_error "    wants app ${app:0:8}…  tenant ${tenant:0:8}…"
            if [[ $have_app == "$tenant" && $have_tenant == "$app" ]]; then
                log_error "  They are SWAPPED — the portal wizard's two GUID fields, filled in"
                log_error "  the wrong order. The Bot Framework then authenticates as an app that"
                log_error "  does not exist and never delivers a message; Teams shows the bot offline."
            fi
            log_error "  msaAppId cannot be changed on an existing bot. Set AZURE_BOT_RECREATE=true"
            log_error "  in config/hermes.conf for one run to delete and recreate it; the Teams"
            log_error "  app then has to be added to a chat again."
            is_true "${AZURE_BOT_RECREATE:-false}" || die "azure: bot identity mismatch"

            log_warn "AZURE_BOT_RECREATE=true: deleting bot ${bot_name}"
            run az resource delete --resource-group "$AZURE_RESOURCE_GROUP" \
                --resource-type Microsoft.BotService/botServices --name "$bot_name" -o none
            mark_changed
            existing=""
        fi
    fi

    local -a params=(
        botName="$bot_name" msaAppId="$app" msaAppTenantId="$tenant"
        endpoint="$endpoint" sku="$AZURE_BOT_SKU"
        displayName="${BOT_DISPLAY_NAME}"
    )
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] what-if for ${template}:"
        az deployment group what-if --resource-group "$AZURE_RESOURCE_GROUP" \
            --template-file "$template" --parameters "${params[@]}" --no-pretty-print -o json 2>/dev/null \
            | jq -r '.changes[]? | "[dry-run]   \(.changeType)  \(.resourceId | split("/") | .[-2:] | join("/"))"' \
            | while IFS= read -r l; do log_info "$l"; done
        return 0
    fi

    local out
    out=$(az deployment group create --resource-group "$AZURE_RESOURCE_GROUP" \
            --name "hermes-bot-$(date +%Y%m%d%H%M%S)" \
            --template-file "$template" --parameters "${params[@]}" -o json 2>&1) ||
        { printf '%s\n' "$out" | tail -20 >&2; die "azure: bot deployment failed"; }
    if [[ -z $existing ]]; then
        mark_changed
        log_ok "bot ${bot_name} created -> ${endpoint}"
    else
        # A deployment that changed nothing is how a declared resource converges.
        log_skip "bot ${bot_name} matches the declaration"
    fi
}

# An app id can back only one Bot Service resource. A bot with our app id under
# another name (the pre-bot-list "hermes-simetrix") blocks the declared one and
# would keep the old Teams endpoint alive; it is retired, and said so.
_az_bot_retire_stale() {
    local app=$1 names n existing have_app
    [[ $DRY_RUN == true ]] && return 0
    names=$(az resource list --resource-group "$AZURE_RESOURCE_GROUP" \
              --resource-type Microsoft.BotService/botServices --query '[].name' -o tsv 2>/dev/null)
    while IFS= read -r n; do
        [[ -n $n && $n != "$BOT_AZURE_NAME" ]] || continue
        existing=$(az resource show --resource-group "$AZURE_RESOURCE_GROUP" \
                     --resource-type Microsoft.BotService/botServices --name "$n" -o json 2>/dev/null) || continue
        have_app=$(jq -r '.properties.msaAppId // ""' <<<"$existing")
        if [[ $have_app == "$app" ]]; then
            log_warn "bot ${n} carries ${BOT_KEY}'s app id; retiring it in favour of ${BOT_AZURE_NAME}"
            run az resource delete --resource-group "$AZURE_RESOURCE_GROUP" \
                --resource-type Microsoft.BotService/botServices --name "$n" -o none
            mark_changed
        fi
    done <<<"$names"
}

_az_verify() {
    [[ $DRY_RUN == true ]] && return 0
    local bot_name=$BOT_AZURE_NAME
    local bot ep chans
    bot=$(az resource show --resource-group "$AZURE_RESOURCE_GROUP" \
            --resource-type Microsoft.BotService/botServices --name "$bot_name" -o json 2>/dev/null) ||
        die "azure: bot ${bot_name} not found after deployment"
    ep=$(jq -r '.properties.endpoint' <<<"$bot")
    chans=$(jq -r '.properties.enabledChannels | join(",")' <<<"$bot")
    [[ $ep == "$(az_bot_endpoint)" ]] || die "azure: bot endpoint is ${ep}, expected $(az_bot_endpoint)"
    [[ ,$chans, == *,msteams,* ]] || die "azure: the Teams channel is not enabled on ${bot_name} (${chans})"
    log_ok "bot endpoint  ${ep}"
    log_ok "bot channels  ${chans}"
}

# ---------------------------------------------------------------------------
# The Teams app package.
#
# A bot is not visible in Teams until it is installed as a Teams APP — a zip of
# manifest.json plus two icons, uploaded once ("Upload a custom app") or
# published to the tenant catalogue. Recreating the bot resource discards that
# installation, which is why a deep link then answers "You do not have
# permission to use this app here". The package is generated from configuration
# so it is the same on every host and every rebuild.
#
# Publishing it to the catalogue over Graph needs AppCatalog.ReadWrite.All,
# which the Azure CLI's own token does not carry; that step stays with the
# operator (Teams -> Apps -> Manage your apps -> Upload an app).
# ---------------------------------------------------------------------------
_az_teams_app_package() {
    local app_id tpl out dir icons
    if [[ $DRY_RUN == true ]] && ! secret_nonempty "$BOT_TEAMS_CLIENT_ID_VAR"; then
        log_info "[dry-run] would build the Teams app package for ${BOT_KEY}"
        return 0
    fi
    app_id=$(secret_require "$BOT_TEAMS_CLIENT_ID_VAR" "the teams app package for ${BOT_KEY}")
    tpl="${SCRIPT_DIR}/bot/teams-app"
    out=$(bot_teams_package "$BOT_KEY")
    # Per-bot icons when the repository has them, the shared ones otherwise.
    icons=$tpl
    [[ -f ${tpl}/${BOT_KEY}/color.png && -f ${tpl}/${BOT_KEY}/outline.png ]] && icons="${tpl}/${BOT_KEY}"
    [[ -f ${tpl}/manifest.json.tpl && -f ${tpl}/color.png && -f ${tpl}/outline.png ]] ||
        die "teams app template incomplete under ${tpl}"

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] build Teams app package -> ${out}"
        return 0
    fi
    ensure_dir "$(dirname "$out")" 0755

    # Rendered and zipped by python3 (a preflight requirement) so a fresh host
    # needs neither envsubst nor zip. Fixed entry order and fixed timestamps:
    # an unchanged configuration yields byte-identical output, so "unchanged"
    # below is honest.
    dir=$(mktemp -d)
    TEAMS_APP_ID="$app_id" TEAMS_APP_NAME="$BOT_DISPLAY_NAME" BOT_VERSION="$(bot_version)" \
    TEAMS_APP_DESCRIPTION="$BOT_DESCRIPTION" \
    TEAMS_APP_DEVELOPER="$TEAMS_APP_DEVELOPER" TUNNEL_HOSTNAME="$BOT_HOSTNAME" \
        python3 - "$tpl" "$icons" "${dir}/package.zip" <<'PY' || { rm -rf "$dir"; die "building the Teams app package failed"; }
import json, os, sys, zipfile
import uuid
tpl, icons, out = sys.argv[1], sys.argv[2], sys.argv[3]
# The Teams app id is NOT the bot's client id. Teams keeps one app per id per
# tenant, and a sideloaded package that lingers after a bot was recreated or
# renamed blocks every upload with "already exists". A stable id derived from
# the client id keeps re-uploads deterministic and free of that collision; the
# bot itself is still addressed by its client id in the bots[] entry.
os.environ["TEAMS_APP_MANIFEST_ID"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "teams-app/" + os.environ["TEAMS_APP_ID"]))
keys = ("TEAMS_APP_ID", "TEAMS_APP_MANIFEST_ID", "TEAMS_APP_NAME", "TEAMS_APP_DESCRIPTION", "TEAMS_APP_DEVELOPER", "TUNNEL_HOSTNAME", "BOT_VERSION")
text = open(os.path.join(tpl, "manifest.json.tpl"), encoding="utf-8").read()
for k in keys:
    v = os.environ.get(k, "")
    if not v:
        sys.exit(f"{k} is empty; the Teams manifest needs it")
    text = text.replace("${" + k + "}", json.dumps(v)[1:-1])
if "${" in text:
    sys.exit("Teams manifest template has an unexpanded placeholder")
json.loads(text)  # must be valid JSON
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in (("manifest.json", text.encode("utf-8")),
                       ("color.png", open(os.path.join(icons, "color.png"), "rb").read()),
                       ("outline.png", open(os.path.join(icons, "outline.png"), "rb").read())):
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, data)
PY
    local tmp="${dir}/package.zip"
    if [[ -f $out ]] && cmp -s "$tmp" "$out"; then
        log_skip "teams app package unchanged: ${out}"
    else
        # Teams updates an installed app only when the SAME id arrives with a
        # HIGHER version; a changed package under an unchanged version leaves
        # the operator with duplicates or "already exists". So a package may
        # only change together with bot/VERSION.
        if [[ -f $out ]]; then
            local old_v new_v
            old_v=$(python3 -c 'import json,sys,zipfile; print(json.loads(zipfile.ZipFile(sys.argv[1]).read("manifest.json"))["version"])' "$out" 2>/dev/null || printf '')
            new_v=$(bot_version)
            if [[ -n $old_v && $old_v == "$new_v" ]]; then
                rm -rf "$dir"
                die "the Teams package for ${BOT_KEY} changed but bot/VERSION is still ${new_v}; bump it (bot/release.sh patch) so Teams updates instead of duplicating"
            fi
        fi
        mv -f "$tmp" "$out"; mark_changed; log_ok "teams app package -> ${out} (v$(bot_version))"
    fi
    rm -rf "$dir"
    [[ -n ${SERVICE_USER:-} ]] && chown "${SERVICE_USER}:${SERVICE_GROUP}" "$out" 2>/dev/null || true

    log_info "  install '${BOT_DISPLAY_NAME}' once in Teams: Apps -> Manage your apps -> Upload an app"
    log_info "  -> Upload a custom app -> ${out}"
}

azure_uninstall() { return 0; }

# ---------------------------------------------------------------------------
# Delegated scopes on the mail app — for EVERY consumer at once.
#
# Admin consent (`az ad app permission admin-consent`) writes one grant per
# resource carrying exactly the scopes the app DECLARES, and it replaces what
# was there — including the per-user grant a device-code sign-in had created
# for the relay's IMAP and SMTP scopes. Consenting for the assistant alone
# therefore silently took the relay's rights away: every IMAP login answered
# "AUTHENTICATE failed" while the token refreshed fine. So the declaration
# carries the relay's Exchange scopes and the assistant's Graph scopes, and
# one consent covers both.
# ---------------------------------------------------------------------------
readonly _AZ_GRAPH_API=00000003-0000-0000-c000-000000000000
readonly _AZ_EXCHANGE_API=00000002-0000-0ff1-ce00-000000000000

_az_mail_app_scopes() {
    local app
    app=$(secret_require "$AZURE_MAIL_APP_ID_VAR" "the mail app")
    if is_true "${MAILPROXY_ENABLED:-false}" && [[ ${MAILPROXY_FLOW:-device} == device ]]; then
        _az_delegated_scopes_ensure "$app" "$_AZ_EXCHANGE_API" "Office 365 Exchange Online" "$MAILPROXY_SCOPES"
    fi
    if is_true "${ASSISTANT_M365_ENABLED:-false}"; then
        _az_delegated_scopes_ensure "$app" "$_AZ_GRAPH_API" "Microsoft Graph" "$ASSISTANT_M365_SCOPES"
    fi
}

_az_missing_scopes() {      # _az_missing_scopes "WANTED..." "HAVE..." -> the wanted not in have
    # Scope lists are space-separated; this program's IFS is newline/tab, so the
    # split is made explicit here and stays inside this function.
    local IFS=$' \t\n' w have
    # shellcheck disable=SC2086  # normalising whitespace is the point
    have=" $(printf '%s ' $2)"
    for w in $1; do
        [[ $have == *" ${w} "* ]] || printf '%s\n' "$w"
    done
}

# _az_delegated_scopes_ensure APP API LABEL "scope names…"
# Declares the named delegated scopes of API on APP (keeping what is already
# declared) and grants admin consent when the grant lacks any of them.
_az_delegated_scopes_ensure() {
    local app=$1 api=$2 label=$3 wanted=$4
    if [[ $DRY_RUN == true ]] && ! az account show >/dev/null 2>&1; then
        log_info "[dry-run] would declare and consent ${label} scopes: ${wanted}"
        return 0
    fi

    local declared names missing granted
    declared=$(az ad app permission list --id "$app" -o json 2>/dev/null |
        jq -r --arg api "$api" '.[] | select(.resourceAppId == $api) | .resourceAccess[] | select(.type == "Scope") | .id')
    names=$(az ad sp show --id "$api" -o json |
        jq -r --argjson ids "$(printf '%s\n' "$declared" | jq -R . | jq -sc .)" \
            '.oauth2PermissionScopes[] | select(.id as $i | $ids | index($i)) | .value')
    missing=$(_az_missing_scopes "$wanted" "$(printf '%s ' "$names")")

    if [[ -n $missing ]]; then
        local -a ids=()
        local id n
        while IFS= read -r n; do
            [[ -n $n ]] || continue
            id=$(az ad sp show --id "$api" --query "oauth2PermissionScopes[?value=='${n}'].id | [0]" -o tsv)
            [[ -n $id ]] || die "${label} has no delegated scope named '${n}'"
            ids+=("${id}=Scope")
        done <<<"$missing"
        log_info "  declaring ${label} scopes on the app: $(echo "$missing" | tr '\n' ' ')"
        run az ad app permission add --id "$app" --api "$api" --api-permissions "${ids[@]}" -o none
        mark_changed
    else
        log_skip "${label} scopes declared on the app"
    fi

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] would verify or grant admin consent for ${label}"
        return 0
    fi
    granted=$(az ad app permission list-grants --id "$app" -o json 2>/dev/null |
        jq -r --arg api "$api" '[.[] | select(.resourceId != null)] | map(.scope) | join(" ")')
    # list-grants does not name the resource; compare against every grant's
    # scope string, which is what the token's scopes are drawn from.
    missing=$(_az_missing_scopes "$wanted" "$granted")
    if [[ -z $missing ]]; then
        log_skip "admin consent covers the ${label} scopes"
        return 0
    fi

    # Consent is granted for what the directory has REPLICATED of the
    # declaration, and a declaration made seconds ago may not be there yet: the
    # call succeeds and the grant still lacks the new scopes. So: consent,
    # re-read the grant, and repeat until it carries every wanted scope.
    log_info "  granting admin consent (${label}): $(echo "$missing" | tr '\n' ' ')"
    local attempt
    for attempt in 1 2 3 4 5 6; do
        az ad app permission admin-consent --id "$app" -o none ||
            die "admin consent failed; the signed-in az account must be a Global or Privileged Role admin"
        sleep 5
        granted=$(az ad app permission list-grants --id "$app" -o json 2>/dev/null |
            jq -r '[.[] | select(.resourceId != null)] | map(.scope) | join(" ")')
        missing=$(_az_missing_scopes "$wanted" "$granted")
        [[ -z $missing ]] && break
        log_info "  grant still lacks $(echo "$missing" | tr '\n' ' ')(attempt ${attempt}/6); the declaration is replicating"
        sleep 5
    done
    [[ -z $missing ]] || die "admin consent for ${label} never reached the grant: $(echo "$missing" | tr '\n' ' ')"
    mark_changed
    _AZ_CONSENT_CHANGED=true
    log_ok "admin consent granted (${label})"
}

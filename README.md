# setup-hermes-agent

A provisioner that turns a clean Linux host into a running [Hermes
Agent](https://github.com/NousResearch/hermes-agent) service — reachable over
Telegram, e-mail and Microsoft Teams, with a full developer toolchain on the
host so the agent can do real work.

**Everything is prepared in the repository; the run deploys it.** Values, keys
and tokens all live under `config/`, gitignored — nothing is edited on the
target before or after an installation, and a rebuilt host comes back identical.
See `docs/decisions/0015`.

**One config, one run, the complete system.** Everything optional is a
configuration toggle — channels, the inbound tunnel, the container sandbox,
backups — so a smaller installation is a *different config*, not a partial one.
The run is idempotent: run it again and it converges, changing nothing that
already matches.

Nothing site-specific lives in the code. Hostnames, endpoints, account names and
credentials come from configuration; a test enforces that.

---

## The whole thing at a glance

```
   PART 1                PART 2               PART 3              PART 4
 ┌───────────┐        ┌───────────┐        ┌───────────┐       ┌───────────┐
 │  Gather   │───────▶│   Fill    │───────▶│  Install  │──────▶│  Two      │
 │credentials│        │  config/  │        │           │       │ sign-ins  │
 └───────────┘        └───────────┘        └───────────┘       └───────────┘
  Telegram             bootstrap.conf       bootstrap.sh         agy  (browser)
  2 mailboxes          install.conf         install.sh           relay(browser)
  Entra × 2            hermes.conf
  Cloudflare           channels.conf
  GitHub, SSH          secrets.conf
```

Nothing in Part 3 works until Part 1 and 2 are complete. The run refuses to
change anything while a declared credential is missing — that is deliberate, so
a half-configured agent never reaches a channel.

---

## What it sets up

- The agent at a **pinned revision**, as a systemd service under a dedicated account
- A **developer toolchain** installed natively — Kubernetes, GitOps, infra-as-code,
  secrets, supply-chain and data tooling — reachable by the service account
- A **bridge** presenting a subscription-authenticated CLI as an ordinary
  OpenAI-compatible endpoint on loopback, translating tool calls in both
  directions so the agent can act without the CLI executing anything itself
- An **OAuth mail relay**, where the mailbox provider has disabled password
  authentication for IMAP
- **Channels** — Telegram, e-mail, Teams (WhatsApp optional) — each behind a
  mandatory sender allowlist
- An **inbound tunnel**, only because Teams needs a public HTTPS endpoint
- A **web dashboard** as its own service behind an authenticating proxy
- **Backups** of the agent's accumulated state: sessions, memories, learned skills

## Requirements

| | |
|---|---|
| Host | systemd, cgroup v2, `git` `curl` `xz` `jq` `python3` |
| Access | root or `sudo` |
| Inference | somewhere to reach an OpenAI-compatible endpoint — no GPU needed here |
| Accounts | see Part 1; most of the work is there, not in the install |

---
---

# PART 1 — Gather the credentials

Everything in this part ends up in **`config/secrets.conf`**, which is
gitignored and mode `0600`. The file is numbered to match the sections below,
so section 3 here is section 3 there.

Configuration refers to secrets **by variable name, never by value**. The
secrets file is *parsed*, not sourced, so a token containing `$`, a backtick or
a semicolon is safe.

### What you will end up with

| # | Where it comes from | Keys | Needed for |
|---|---|---|---|
| 2 | Telegram BotFather | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_IDS` | Telegram channel |
| 3 | Your two mailboxes | `EMAIL_PRIVATE_PASSWORD`, `EMAIL_WORK_PASSWORD`, `EMAIL_ALLOWED_SENDERS` | E-mail channel |
| 5 | Microsoft Entra | `AZURE_TENANT_ID`, `MAIL_CLIENT_ID` | Mail relay (OAuth) |
| 5 | Microsoft Entra | `TEAMS_CLIENT_ID`, `TEAMS_CLIENT_SECRET`, `TEAMS_ALLOWED_OBJECT_IDS` | Teams channel |
| 6 | Cloudflare | `CF_API_TOKEN`, `CF_ACCOUNT_ID` | Inbound tunnel |
| 7 | You invent it | `DASHBOARD_PASSWORD` | Web interface |
| 8 | GitHub | `GITHUB_TOKEN` | Release lookups during install |
| — | `ssh-keygen`, in this repo | `config/credentials/ssh/id_ed25519` | The agent's git access |

---

## 1.1 · Telegram — read this before creating a bot

**A Telegram bot cannot be private.** Its username is discoverable; anyone who
knows or guesses it can open a chat and send messages. There is no setting that
hides one. What protects the agent is the sender allowlist — messages from
anyone else are ignored — but the bot's existence and name are public.

If that is unacceptable, leave `CHANNEL_TELEGRAM_ENABLED=false` and use a
channel tied to a real identity instead:

| Channel | Addressability |
|---|---|
| **Teams** | a real account in your tenant; only people in it can see it |
| **WhatsApp** (bridge mode) | a real account — a phone number you give out |
| SimpleX | no identifiers at all; connection by one-time invitation link |
| Matrix | a real account on a homeserver you control |
| Telegram | bot username, publicly discoverable |

The agent ships adapters for all of these; this provisioner configures the
first four channels listed in `config/channels.conf`.

If you do want the bot:

```
Open Telegram  →  talk to  @BotFather
  /newbot  →  display name, then a username ending in "bot"
  → token like  8123456789:AAH...
talk to  @userinfobot   →  your numeric Id
```

```bash
TELEGRAM_BOT_TOKEN="8123456789:AAH..."
TELEGRAM_ALLOWED_IDS="123456789,987654321"     # COMMA-separated — see §2.2
```

## 1.2 · E-mail — the private mailbox

The agent has **two** mailboxes and uses one of them. They are named
`PRIVATE` and `WORK` throughout the configuration so it is never in doubt which
is meant.

The private one is a consumer mailbox (Gmail in the reference config) and works
with an **app password** today.

```
Google Account  →  Security
  1. 2-Step Verification must be ON  (app passwords do not exist without it)
  2. Search "App passwords"  →  create one
  3. Copy the 16 characters. Spaces are cosmetic; keep or strip them.
```

```bash
EMAIL_PRIVATE_PASSWORD="abcd efgh ijkl mnop"
```

Hosts are already in `config/channels.conf`:

```bash
CHANNEL_EMAIL_PRIVATE_ADDRESS="agent@example.com"
CHANNEL_EMAIL_PRIVATE_IMAP_HOST="imap.gmail.com"
CHANNEL_EMAIL_PRIVATE_SMTP_HOST="smtp.gmail.com"
```

---

## 1.3 · E-mail — the work mailbox, and why it needs a relay

**Verified, not assumed:**

```
$ openssl s_client -connect outlook.office365.com:993 -quiet
  * OK ... CAPABILITY ... AUTH=XOAUTH2 LOGINDISABLED
  → "Basic authentication is disabled."

$ openssl s_client -connect smtp.office365.com:587 -starttls smtp
  250-AUTH LOGIN XOAUTH2          ← sending works, receiving does not
```

Microsoft disabled IMAP basic authentication **tenant-wide** and it cannot be
re-enabled. The Hermes e-mail adapter speaks no OAuth2. So an M365 mailbox is
unreachable directly — and mail forwarding was ruled out, because the agent is
meant to *be* that mailbox, not a copy of it.

The way through is a **local OAuth relay**:

```
   Hermes adapter                relay                     Microsoft
   ──────────────                ─────                     ─────────
   IMAP/SMTP  ──────────▶  127.0.0.1:1993/1587  ──────────▶  outlook.office365.com
   plain password                holds the                    XOAUTH2
                                 OAuth token
```

The relay accepts any login on loopback and authenticates upstream with OAuth.
`EMAIL_WORK_PASSWORD` is therefore what the *adapter* presents to the *relay* —
reuse the mailbox's app password so there is not a second secret to lose.

> **The loopback hop is TLS too.** The pinned agent connects with
> `imaplib.IMAP4_SSL` and offers no alternative — `imap_security` exists on the
> vendor's `main` branch and in no release. So the relay holds a self-signed
> certificate for `127.0.0.1`, generated once by the run and installed into the
> system trust store, which is what a default SSL context verifies against.
> Read the **pinned** source when checking what the agent does; `main` said
> "plain" was fine, and it was — for a version that is not installed here.

```bash
EMAIL_WORK_PASSWORD="<the M365 app password>"
EMAIL_ALLOWED_SENDERS="you@example.com other@example.com"
```

`EMAIL_ALLOWED_SENDERS` is the allowlist: mail from anyone else is ignored.

Which mailbox is actually used is one line in `config/channels.conf`:

```bash
CHANNEL_EMAIL_ACCOUNT="work"        # private | work
```

> Leave the **real** hosts in `channels.conf`. When `MAILPROXY_ENABLED=true`
> the run redirects them to loopback by itself, and the address stays what the
> relay authenticates as.

---

## 1.4 · Microsoft Entra — the app registration for the mail relay

This gives the relay an identity to perform OAuth with. It needs **no admin
consent** in the device-code flow.

```
portal.azure.com  →  Microsoft Entra ID  →  App registrations  →  New registration

  Name                     hermes-mail-relay
  Supported account types  Accounts in this organizational directory only
  Redirect URI             Public client/native (mobile & desktop)
                           https://login.microsoftonline.com/common/oauth2/nativeclient
  → Register
```

Then, on the new registration:

```
Authentication
  Allow public client flows            →  Yes          ← required for device code

API permissions  →  Add a permission  →  APIs my organization uses
  Office 365 Exchange Online  →  Delegated permissions
      IMAP.AccessAsUser.All
      SMTP.Send
  Microsoft Graph  →  Delegated
      offline_access                                   ← without it there is no refresh token

Overview
  Application (client) ID   →  MAIL_CLIENT_ID
  Directory (tenant) ID     →  AZURE_TENANT_ID
```

```bash
AZURE_TENANT_ID="00000000-0000-0000-0000-000000000000"
MAIL_CLIENT_ID="11111111-1111-1111-1111-111111111111"
```

> `AZURE_TENANT_ID` is **one** key, shared by the relay and Teams. They are in
> the same tenant; two keys holding the same value is a chance for them to
> disagree.

Flow choice, in `config/hermes.conf`:

| `MAILPROXY_FLOW` | What it costs you | What it needs |
|---|---|---|
| `device` *(default)* | one browser sign-in, once | nothing from an admin |
| `client_credentials` | unattended from the start | an admin granting application permissions |

---

## 1.5 · Microsoft Teams — the bot

Teams is the only channel that needs the machine to be reachable from the
internet: the Bot Framework **posts to you**. The bot itself — the Azure Bot
resource, its messaging endpoint and its Teams channel — is **declared in this
repository** (`src/azure/bot.bicep`) and deployed by the run. What you create by
hand is the app registration it authenticates as; what you do once is sign the
Azure CLI in.

**The app registration** (Entra, not the bot):

```
portal.azure.com  →  Microsoft Entra ID  →  App registrations  →  New registration
  Name                     Hermes Teams
  Supported account types  Accounts in this organizational directory only
  → Register
  Certificates & secrets  →  New client secret  →  copy the VALUE  →  TEAMS_CLIENT_SECRET
  Overview  →  Application (client) ID                            →  TEAMS_CLIENT_ID
```

**Your object ID** — the Teams allowlist is by Entra object ID, not by e-mail:
`Microsoft Entra ID → Users → you → Object ID` → `TEAMS_ALLOWED_OBJECT_IDS`.
It is the ID of the *person who writes to the bot*, not of the mailbox account
the agent uses. The gateway names the rejected sender in its journal —
`Unauthorized user: <object id> (<display name>) on teams` — so a wrong entry
is a copy-and-rerun fix; the installer rewrites the allowlist and restarts.

```bash
TEAMS_CLIENT_ID="22222222-2222-2222-2222-222222222222"      # the APP, not the tenant
TEAMS_CLIENT_SECRET="<the secret VALUE>"
TEAMS_ALLOWED_OBJECT_IDS="33333333-3333-3333-3333-333333333333"
```

**The bot** is configured in `config/hermes.conf` and created by the run:

```bash
AZURE_MANAGE=true
AZURE_SUBSCRIPTION_ID="<subscription id>"
AZURE_RESOURCE_GROUP="<resource group>"       # created if absent
AZURE_BOT_NAME="hermes-<site>"
AZURE_BOT_DISPLAY_NAME="<name shown in Teams>"
AZURE_BOT_SKU="F0"                            # free tier is enough for one person
```

The run installs the Azure CLI from Microsoft's apt repository if it is
missing, verifies both Entra apps against the IDs in the secrets file, creates
the resource group and the bot, sets the endpoint to
`https://<TUNNEL_HOSTNAME>/api/messages`, and enables the Teams channel. On a
re-run it changes nothing.

> **Two GUIDs, one trap.** The bot needs the *app* ID and the *tenant* ID, and
> the portal wizard presents them as two unlabeled fields. Swapped, the Bot
> Framework authenticates as an app that does not exist, never delivers a
> message, and Teams shows the bot offline with no error anywhere. The run
> detects exactly this case on an existing bot and names it. `msaAppId` is
> immutable, so the fix is `AZURE_BOT_RECREATE=true` for one run.

**Bots are a list.** `BOTS="secretary search news"` in `config/hermes.conf` gives
three bots, each its own 1:1 chat in Teams with its own name and icon, its own
gateway service and profile (persona from `bot/roles/<key>.md`, own memory and
tools), its own hostname (`<key>.<zone>`) and webhook port. The run creates each
bot's Entra app (client id and secret are written into the secrets file), the
Azure Bot, the Teams package and the service. One bot carries the mailbox
(`BOT_<KEY>_CHANNELS="teams email"`), one the dashboard, and the assistant's
tools go to the bots that list them (`BOT_<KEY>_MCP="m365"`). See ADR 0020.

**What /help shows.** The agent's own `/help` is eighty developer commands under
its own name; in a Teams chat that is unreadable. A carried patch makes the
gateway answer a bare `/help` with the profile's `HELP.md`, which the run
renders from `bot/help/<role>.md` (what the bot does, examples) plus the shared
command block `bot/help/_commands.md`; a role without its own page gets
`bot/help.md.tpl` with the one-line summary from the role file (the `> …` line
under its title). Teams keeps only bold, `- ` lists and paragraph breaks of
markdown, so the pages are written that way. `/help all` and `/help skills`
still reach the original.

**What a bot may run without asking.** The agent stops before a dangerous
command — inline scripts (`python3 -c`, `bash -c`), recursive deletes, and the
like — and asks in the chat; "Always allowed" whitelists that category for the
profile, in its `command_allowlist`. `CHANNELS_COMMAND_ALLOWLIST` (per bot
`BOT_<KEY>_COMMAND_ALLOWLIST`, semicolon-separated) records the same choice in
configuration, so a rebuilt host has it: the run adds the entries and keeps
whatever the chat added on top. Widen this only for bots whose senders are yours
alone — an allowlisted category is what an injected instruction in a mail or a
document could use without a pause.

**Which toolsets a bot gets.** `BOT_<KEY>_TOOLSET` (default `CHANNEL_TEAMS_TOOLSET`,
`hermes-telegram` — the agent's core set with terminal, files, browser, memory,
cron) takes either one composite or a space-separated list of the agent's
toolsets (`web memory session_search clarify cronjob todo`, …). The list is how
a bot runs **without a shell**: the GitHub bot, for one, reached for `gh` in the
terminal instead of its GitHub tools until the terminal was gone. MCP servers
join every list on their own; names are checked against the installed registry.

Left at the default, the **role decides** (ADR 0026): a role whose own text says
"never write files, use the web tools" is not handed a terminal, because a bot
reaches for what it has. News and Search therefore default to `web [browser]
memory session_search clarify cronjob todo`; every other role to the composite.
`BOT_<KEY>_TOOLSET`, and `CHANNEL_TEAMS_TOOLSET` set to anything but
`hermes-telegram`, override that.

**Which tools the model sees.** `AGENT_TOOL_SEARCH` — `off` (default) puts
every MCP tool in front of the model by name; `auto`/`on` hides them behind the
agent's three meta-tools (`tool_search`, `tool_describe`, `tool_call`), which
saves context on huge catalogues but made the bridge model reach for `gh` in the
terminal instead of the GitHub tools. Per bot: `BOT_<KEY>_TOOL_SEARCH`.

**Reminders survive a model switch.** The agent refuses to run a cron job whose
bot has changed provider or model since the job was made, unless the job is
pinned — a spend guard that would silence every reminder after a switch to a
cheaper model or to the balance proxy. `AGENT_CRON_DRIFT_GUARD=false` (the
default here) turns it off; a one-shot reminder the guard has already consumed
is gone and has to be set again.

**When a chat starts over.** `AGENT_SESSION_RESET` — `none`, `daily@HOUR` (host
time) or `idle@MINUTES` — with `BOT_<KEY>_SESSION_RESET` per bot. A reset empties
the transcript only: memory, files, calendar and cron jobs live outside it. With
an API model this is cost hygiene (the first turn after a pause pays for the whole
transcript); with the bridge it is also what keeps a long chat from dragging a
stale context around.

**Several bots, one mailbox.** Mail is one account (the agent's), but every
bot can have its own address on it: add an alias in Exchange (e.g.
`news@example.com`), set `BOT_NEWS_MAIL_ALIAS` and give the bot the `email`
channel. The run creates a folder named after the bot and an inbox rule that
sorts mail to that alias into it; the bot polls that folder. One bot reads
INBOX (`BOT_<KEY>_MAIL_CATCH_ALL=true`) and gets everything else. This needs a
two-line patch to the pinned agent's e-mail adapter (a configurable folder),
which the run applies and re-applies after updates — see `60-hermes.sh`.
Replies are sent from the mailbox's primary address; sending as the alias
needs Exchange's "send from alias" setting.

**A bot may run on its own model.** `BOT_<KEY>_LLM_MODEL` (with `_LLM_PROVIDER`,
`_LLM_NAME`, `_LLM_BASE_URL`, `_LLM_TOKEN_VAR`, `_LLM_REASONING_FIELD`,
`_LLM_CONTEXT_WINDOW`) replaces the global endpoint for that bot's profile — a
real model API for the bot that needs exact tool calling and images, the bridge
for the others. The key stays in the secrets file under the name `_LLM_TOKEN_VAR`
gives. A hosted provider the agent knows (`deepseek`, `anthropic`, `openai`,
`openrouter`, `kimi-coding`, …) takes no base URL; `custom` is any
OpenAI-compatible endpoint with one.

**The balance at the end of every answer.** `BOT_<KEY>_LLM_BALANCE=true`
appends the account's remaining API balance to each final answer of a bot on
DeepSeek or Moonshot — `(DeepSeek-Guthaben: 18.42 USD)`. A loopback proxy
(module `apiproxy`, one instance per provider) sits between the bot and the
provider, forwards every request unchanged with the bot's own key, and, when a
turn ends as a message rather than a tool call, adds the line; the balance
endpoint is free and cached for `API_PROXY_CACHE` seconds. Tool-call turns are
untouched. The footer lands in the bot's history as a dozen tokens per turn,
which is the whole cost.

**A bot's sub-agents may run elsewhere.** The agent's `delegate_task` tool
hands work to sub-agents, which inherit the bot's tools. With
`BOT_<KEY>_DELEGATION_ENDPOINT=<n>` they run on the global `LLM_ENDPOINT_<n>`
instead of the bot's own model — the way a bot on an API model keeps the
reading of your own mailboxes (1.10, 1.11) on the subscription bridge: the
sub-agent reads and extracts there, the bot on the API sees only the extract.
Two shapes are possible, a keyless custom endpoint (the bridge) or a hosted
provider by name; a custom endpoint with a key is refused, because the block
would have to carry the key in `config.yaml`.

**Install each bot in Teams — once, after the first run.** A bot is not visible
in Teams until it is installed as a Teams *app*. The run generates one package
per bot at `bot/build/<key>-teams-app.zip` (manifest + icons, deterministic).
Upload each:

```
Teams  →  Apps  →  Manage your apps  →  Upload an app  →  Upload a custom app
       →  bot/build/<key>-teams-app.zip  →  Add   (then /sethome in that chat)
```

The app is named after the bot (`AZURE_BOT_DISPLAY_NAME`, override with
`TEAMS_APP_NAME`); the developer line under it comes from `TEAMS_APP_DEVELOPER`
(default: `GIT_USER_NAME`); `TEAMS_APP_PACKAGE` moves the output. To ship a
changed package, bump the bot version first (`bot/release.sh patch`); Teams then
updates the installed app in place. The run refuses to build a changed package
under an unchanged version, because that is what produces duplicates and
"already exists".

The manifest declares `supportsFiles`, which is what puts the attach button into a 1:1 bot chat — without it, nothing can be uploaded to the bot.

Recreating the bot resource discards the installation; a deep link then answers
"You do not have permission to use this app here" — upload the package again.
The package's app id is derived from the bot's client id, not equal to it: Teams
keeps one app per id, and a lingering earlier upload with the client id as its
app id would otherwise block every new upload with "already exists". A ghost
that Teams no longer lists can be removed in the Developer Portal
(dev.teams.microsoft.com → Apps) or the Teams Admin Center → Manage apps.
Publishing to the tenant catalogue over Graph needs `AppCatalog.ReadWrite.All`,
which the Azure CLI's token does not carry, so this step stays manual.

**Sign the CLI in** — once, as the account that will run the installer:

```bash
az login --use-device-code --tenant <AZURE_TENANT_ID>
```

## 1.6 · Cloudflare — the inbound tunnel

The tunnel is what makes Teams reachable without opening a port. The run creates
the tunnel, the DNS record and the ingress rule over the API.

```
dash.cloudflare.com  →  My Profile  →  API Tokens  →  Create Token  →  Custom token

  Permissions
    Account  ·  Cloudflare One Connector: cloudflared  ·  Write
    Zone     ·  Zone                                   ·  Read
    Zone     ·  DNS                                    ·  Edit
    Zone     ·  SSL and Certificates                   ·  Edit   ← lets the run enable Universal SSL

  Zone Resources
    Include  ·  Specific zone  ·  your-zone.example
```

> The permission is listed under **Cloudflare One Connector: cloudflared**.
> An older entry named *Cloudflare Tunnel* still appears in some accounts — that
> one is legacy; use the Connector permission.

**Account ID**: the dashboard overview shows it in the right-hand column, and it
is also the hex string in the dashboard URL.

```bash
CF_API_TOKEN="<token>"
CF_ACCOUNT_ID="<32 hex characters>"
```

And in `config/hermes.conf`:

```bash
TUNNEL_HOSTNAME="hermes.your-zone.example"
TUNNEL_ZONE="your-zone.example"
```

> **Do not** validate this token with Cloudflare's *Test* button as proof of
> anything: `/user/tokens/verify` describes **user-owned** tokens only and
> answers `Invalid API Token` for a perfectly good account-owned one. The run
> verifies by exercising the two permissions it actually needs, and names which
> is missing.

---

## 1.7 · GitHub — release lookups

Not a credential for the agent. The installer resolves “latest release” once per
developer tool, and GitHub allows **60 such calls per hour per IP**
unauthenticated. The catalogue needs **42** — so a first run fits and a second
inside the hour does not, which makes a re-runnable installer impossible.

```
github.com/settings/tokens  →  Generate new token (classic)
  Tick NO scopes at all.
```

An unscoped token reads public release metadata and can do nothing else. That is
the point: this token lands on a host where an agent processes untrusted mail.

```bash
GITHUB_TOKEN="ghp_..."
```

and in `config/install.conf`:

```bash
DEVTOOLS_GITHUB_TOKEN_VAR="GITHUB_TOKEN"
```

To go without one, clear that pointer and leave the secret empty — the run then
works, but only once an hour.

---

## 1.8 · The agent's SSH key

Generate it **here, in the repository, before installing**. Two reasons:

1. You can register the public half with your forge before the agent exists, so
   it can push from its first minute.
2. `bootstrap.sh` mirrors with `rsync --delete`. A key generated only in the
   copy is deleted on the next mirror, and you would get a different key each
   time while the registered one silently stops matching.

```bash
ssh-keygen -t ed25519 -f config/credentials/ssh/id_ed25519 -N "" -C "hermes@<host>"
cat config/credentials/ssh/id_ed25519.pub
```

Register the public key with your forge, then confirm:

```bash
ssh -i config/credentials/ssh/id_ed25519 -o IdentitiesOnly=yes -T git@github.com
# → Hi <you>! You've successfully authenticated ...
```

> **Scope.** An account-level key gives the agent the same repository access you
> have. A deploy key on a single repository gives it less. Decide which, rather
> than inheriting the first one that works.

---

## 1.9 · Dashboard password

Invent it. It guards an interface that displays and edits every credential
above, and it is typed by a browser, never by you.

The dashboard enforces **its own login** whenever its public URL is
non-loopback (the run configures that). The basic-auth layer at the proxy is
therefore a second prompt for the same door; `DASHBOARD_PROXY_AUTH=false` turns
it off, and the run refuses to finish if neither layer is gating.

```bash
DASHBOARD_PASSWORD="<long>"
```

The run warns if it is short. The interface is published over plain HTTP on the
LAN address you configure, so this password and everything it shows cross the
network in clear text — see `docs/decisions/0012`.

---
---

## 1.10 · The assistant — Microsoft 365 as the agent's hands

Channels let people talk to the agent. The **assistant** lets the agent act:
read and send mail, keep the calendar, create Teams meetings with roles, file
and read documents in OneDrive. It is an MCP server from `bot/mcp/`, run by the
gateway, acting **as the agent's own mailbox account** — never as you.

What it needs, and who does it:

| Step | Who | When |
|------|-----|------|
| Delegated Graph scopes on the app "Hermes Mail" (`Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `OnlineMeetings.ReadWrite`, `Files.ReadWrite`, `User.Read`, `offline_access`) | the run, via `az`, when `AZURE_MANAGE=true` | every run, idempotent |
| Admin consent for those scopes | the run, via `az` (the signed-in account must be an admin) | once |
| Sign-in as the agent's mailbox account | **you**, device code, private browser window | once |
| Virtualenv, code, registration in `config.yaml`, gateway restart | the run | every run, idempotent |

The rule the agent follows: **business is the default and goes to Microsoft
365**; when you say *privat*, *privater Termin* or name the Gmail account, it
uses the Google tools (part 1.11, when enabled). Both servers say so in their
own instructions, so the model routes by itself.

Configuration (`config/hermes.conf`):

```bash
ASSISTANT_M365_ENABLED=true
ASSISTANT_M365_ACCOUNT="agent@example.com"      # the mailbox account; the token is refused for any other identity
ASSISTANT_M365_TIMEZONE="Europe/Zurich"
# defaults you rarely touch: ASSISTANT_M365_SCOPES, ASSISTANT_STATE_DIR (/var/lib/hermes-assistant),
# ASSISTANT_LIB_DIR (/usr/local/lib/hermes-assistant), ASSISTANT_PYPDF_VERSION, ASSISTANT_DOCX_VERSION, ASSISTANT_LOGIN_TIMEOUT
```

The working folder: the run creates `ASSISTANT_M365_ROOT_FOLDER` (default
`Secretary`) in the agent's OneDrive and gives everyone in
`ASSISTANT_M365_SHARE_WITH` the `ASSISTANT_M365_SHARE_ROLE` (default `write`), so
whatever the agent files is in your reach in your own OneDrive under *Shared*.

**Private and business apart.** `ASSISTANT_M365_WORLDS="Business=_bus,Private=_pri"`
divides the root folder into one sub-folder per world and makes every file name
end with the world's suffix before the extension
(`Secretary/Business/Letters/2026/2026-09-07 lease_bus.pdf`). This is not a
convention the model is asked to keep: the drive tools that write — upload,
mkdir, move — refuse a path that breaks it and answer with the corrected name,
so the model files it right on the next try. The role decides the world before
anything else (business by default, private when the document or the operator
says so, one question when it cannot tell). Existing files are moved once:
`m365ctl migrate-worlds` prints where each file below the root would go (the
first world unless a folder name says otherwise, suffix added),
`m365ctl migrate-worlds --apply --default=Business` does it. The run creates
the world folders; the share is inherited from the root.

**The drop folder — from the phone.** Teams on Android and iOS offers only
people and channels as share targets, never a bot. The way in is OneDrive: the
Secretary's folder is shared with you, so the OneDrive app on the phone (and the
Explorer on the PC) can put a photo or a file into `Secretary/Business/Inbox/`
or `Secretary/Private/Inbox/` — the run creates both (`ASSISTANT_M365_INBOX`).
The same drop folders exist in the agent's Google Drive. The Secretary watches
both with a cron job whose `monitor` is `inboxctl`, a free joint listing
compared between ticks: only a change wakes the model, which then reads each
file, names it, files it into the world's proper folder with the suffix and the
Markdown twin (`m365_drive_file` / `google_drive_file`, one call), and reports
the new path. The folder a file was dropped into decides the world.

**Every document with its text.** A scan, photo, PDF or Word file filed below
the root is filed together with a Markdown twin of the same name
(`2026-09-07 lease_bus.jpg` + `2026-09-07 lease_bus.md`) holding the recognized
text — searchable, quotable, readable without the scan. The upload tools take it
as `text_md`; a photo without it is refused, a PDF with a text layer is extracted
by the server. `m365ctl companions` lists documents without a twin,
`--apply` writes the twins the server can extract and names the photos and
scans that need the Secretary's eyes (ask the bot to backfill them: it lists,
downloads, reads and uploads). The same in Drive: `googlectl companions`.

**Reading your own mailbox.** For receipts, invoices and letters that arrive in
*your* mailbox rather than the agent's, list it in `ASSISTANT_M365_READ_MAILBOXES`
(comma-separated). The agent then reads it — search, read, attachments,
folders — and nothing else: the tools that send, move or mark have no mailbox
parameter. Two grants make a mailbox readable:

| Grant | Who | Where |
|-------|-----|-------|
| Scope `Mail.Read.Shared` on the app registration, consented | the run (added to `ASSISTANT_M365_SCOPES` automatically when the list is non-empty) | — |
| Full Access delegation for the agent's account on your mailbox | **you**, once, signed in as a **tenant admin** (not as the agent) | Exchange admin center → Recipients → Mailboxes → your mailbox → *Delegation* → *Read and manage (Full Access)* → Add → the agent's account |

Exchange applies the delegation within about an hour. The run checks each
mailbox (`m365ctl check-mailbox <address>`) and, while it is not readable yet,
prints exactly that click path and carries on. If the bot runs on an API model,
set `BOT_<KEY>_DELEGATION_ENDPOINT` (part 1.5) so the reading happens on the
bridge — the role tells the Secretary to hand these analyses to sub-agents. Full Access is the only
delegation the admin center offers; the read-only limit is enforced by the
server, whose write tools never take a mailbox.

Meeting roles: **co-organizers must be accounts of the tenant** (you); people
outside can be **presenters**. Everyone named in a role is invited as an
attendee too, and Exchange sends the invitations by mail.

Documents: pdf, docx and plain text come back as text. A scanned PDF without a
text layer is reported as such — OCR is not part of this release.

---

## 1.11 · The assistant — Google, the private account

The second world. The same server shape as 1.10, acting as the agent's own
Gmail account, and used **only when you say so** ("privat", "privater Termin",
or the Gmail address by name). Gmail (search, read, reply, send, labels,
attachments as text), Google Calendar (view, create with Meet, update, delete),
Drive (list, search, read, upload, folders, move, share).

| Step | Who | When |
|------|-----|------|
| gcloud CLI installed | the run | once |
| `gcloud auth login` as the agent's Google account, project set | **you**, once (`sudo -u <account> -H gcloud auth login --no-launch-browser`) | once |
| Gmail, Calendar, Drive, People APIs enabled on the project | the run | idempotent |
| OAuth client of type **Desktop app** | **you**, once, in the console — Google removed the API for this in 2026; the run prints the exact steps | once |
| Sign-in as the Gmail account (paste-back: open a URL, paste the address you land on) | **you**, once, in the run or via `googlectl login` | once |
| Code, env file, registration in the bots that list `google` | the run | idempotent |

Publish the OAuth app ("In production") after adding the account as test user:
in *Testing* status Google expires refresh tokens after seven days and the
sign-in would be needed weekly.

```bash
ASSISTANT_GOOGLE_ENABLED=true
ASSISTANT_GOOGLE_ACCOUNT="agent@example.com"
GOOGLE_PROJECT="my-assistant-project"
ASSISTANT_GOOGLE_READ_ACCOUNTS=""               # your own Gmail accounts, read-only (below)
# secrets file: GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET
# bots: BOT_SECRETARY_MCP="m365 google"
```

**The same worlds in Drive.** `ASSISTANT_GOOGLE_ROOT_FOLDER` and
`ASSISTANT_GOOGLE_WORLDS` (empty: the Microsoft 365 values) give the agent's
Drive the structure of 1.10 — one sub-folder per world, the suffix in every file
name, enforced by the Drive tools that write; the run creates the folders and
`googlectl migrate-worlds [--apply]` moves what is already there.

**Reading your own Gmail.** Your private Gmail is a different Google account,
so it gets its own token: list the address in `ASSISTANT_GOOGLE_READ_ACCOUNTS`
and the run asks for one more paste-back sign-in — **as that account**, with
the read-only scope (`gmail.readonly`) only. The token is stored next to the
agent's (`google-<address>.token`); the Gmail search/read/attachment/labels
tools take an `account` parameter, the tools that send or modify do not. Two
things to expect on the consent screen: the app is yours but *unverified*, so
Google shows a warning — *Advanced → go to … (unsafe)* is the way through; and
if the app is still in *Testing* status the account must be listed as a test
user first (published apps take any account). Later, without the run:

```bash
sudo -i                                                                           # one root shell, one terminal
runuser -u <account> -- /usr/local/lib/hermes-assistant/googlectl login you@gmail.example    # sign in AS you@gmail.example
runuser -u <account> -- /usr/local/lib/hermes-assistant/googlectl status you@gmail.example
```

---

## 1.12 · The public pages

Google publishes an external OAuth app only with a home page, a privacy policy
and terms of service on an authorized domain; Teams shows the same links in an
app's details. `SITE_ENABLED=true` renders the three pages from `bot/site/` with
`SITE_OWNER` and `SITE_CONTACT`, serves them with nginx on loopback and
publishes `assistant.<zone>` through the tunnel:

```
https://assistant.example.com/     https://assistant.example.com/privacy     https://assistant.example.com/terms
```

Enter those three on Google's Branding page (App domain), add `<zone>` under
Authorized domains, save — then Audience → Publish app.

---

## 1.13 · The assistant — GitHub

A bot for the operator's repositories: the official `github/github-mcp-server`
(Go binary, pinned by `ASSISTANT_GITHUB_MCP_VERSION`, checksum-verified against
the release's checksums file) registered in the bots that list `github` in
their MCP field. It authenticates with a **fine-grained personal access token**
in the secrets file (`GITHUB_MCP_TOKEN`), limited to the repositories the bot
may see; the token reaches the server through an env file the wrapper
`githubctl` sources, never through `config.yaml`. Toolsets in
`ASSISTANT_GITHUB_TOOLSETS`; `ASSISTANT_GITHUB_READ_ONLY=true` blocks every
write. The role (`bot/roles/github.md`) reads freely, writes on instruction and
merges or deletes only on explicit confirmation.

---

## 1.14 · The Admin bot

A fifth kind of bot, for the operator alone: it answers what state the host is
in, what could be updated, and it turns a change request into a reviewed
commit — by running **Claude Code** inside the repository checkout, with the
model `OPS_CLAUDE_MODEL` (default `opus`), through the service account's own
`claude` sign-in (part 3.3, no API key). The bot itself runs on the bridge; it
only orchestrates.

It has exactly one instrument, `opsctl`, installed by the `ops` module:

| Command | What it does | Writes |
|---------|--------------|--------|
| `opsctl status` / `report` | units, failed units, disk, memory, versions, bridge health, errors of the last 24 h, last installer run | nothing |
| `opsctl check-updates` | newest agent tag, newest GitHub MCP server release, repository vs. remote | nothing |
| `opsctl dry-run [modules]` | the installer's preview | nothing |
| `opsctl change "<request>"` | Claude Code edits, tests, commits; opsctl verifies with `tests/run.sh`, pushes, then applies or names the command (`OPS_APPLY`) | the repository, then the host |
| `opsctl apply [modules]` / `apply-status` | writes a request; a root-side path unit runs the installer with a log; the bots restart as the run decides — the Admin bot included | the host |

Two things are kept apart on purpose. **Claude Code changes the repository and
nothing else**: its tool allowlist has no `install.sh`, `systemctl restart`,
`sudo` or `git push`, and one change runs at a time (a lock). It does see the
host: every change starts with a read-only snapshot (`opsctl snapshot` — status,
the recent warnings of every unit, the profiles' configuration blocks, the
assistants' state) and may run the read-only commands itself (`journalctl`,
`systemctl status`, `opsctl status`, `m365ctl status|inbox|companions`), so a
request about behaviour is diagnosed against the live state, not guessed. **Applying is opsctl's
step**, deterministic and only after the suite passed and the commit is
pushed — `OPS_APPLY=auto` does it right away, `ask` (the default) has the bot
offer it and wait for your word, `never` leaves the installer to your terminal.
The bots run under `NoNewPrivileges`, where no escalation can work, so the bot
never escalates: `opsctl apply` writes `/var/lib/hermes-ops/apply.request`, and
the root-side `hermes-ops-apply.path` starts `apply.sh`, which runs exactly one
command — `./install.sh [--only …]` from the repository — and logs where the
account can read. Because a run restarts the bots, the Admin bot itself may go
quiet for a minute; `opsctl apply-status` shows the log afterwards. The Claude Code session
is the bot's own and persists between requests, so a follow-up has the context
of the last one.

```bash
BOTS="secretary search news github admin"
BOT_ADMIN_CHANNELS="teams"                       # no mail: change requests come from you, in Teams
BOT_ADMIN_TOOLSET="terminal memory session_search clarify cronjob todo web"
OPS_ENABLED=true
OPS_CLAUDE_MODEL="opus"
OPS_CLAUDE_TIMEOUT=1500
OPS_APPLY="ask"                                  # auto | ask | never
```

What the bot needs from you: nothing new — the `claude` CLI is signed in for the
service account (3.3a), and the bot's Teams app is installed like the others
(1.5). On first contact it sets up a daily `opsctl report` at 07:00 in its chat.

## 1.15 · The Tasks bot — tasks per tenant in Microsoft Planner

A sixth kind of bot, for tasks: one sentence in its chat or a mail to its
alias ("Acme neuer Task: RP anpassen, sobald der Kunde die Details liefert,
CASE-2323") becomes a card in **Microsoft Planner** — in the bucket of the
tenant named, with the reference, and with a start and a due date the bot
asks for when the sentence has none. Every card is assigned to you, so it is
in your Planner app and in To Do ("Assigned to me") on the phone without the
bot in between. The store is Planner, not a file of the bot's: what you change
in the app, the bot sees; what the bot creates, you see.

Why Planner and not To Do or a store of the bot's own: To Do lists live in a
mailbox, and writing into *yours* would need an application permission over
every mailbox in the tenant, or a list shared by hand per tenant. A Planner
plan lives in a Microsoft 365 group; the agent's account is a member, the
delegated scope `Tasks.ReadWrite` is all it needs, and a tenant is one
bucket the bot can add on your word. Decision record 0023.

What the run does, with `AZURE_MANAGE=true` and the signed-in admin:

| Step | Who | When |
|------|-----|------|
| Scope `Tasks.ReadWrite` declared and consented on the mail app | the run (azure module) | once |
| The Microsoft 365 group `ASSISTANT_TASKS_GROUP`: you as owner and member, the agent's account as member; a Team on it when `ASSISTANT_TASKS_TEAM=true` | the run (azure module) | once, then verified |
| The group's id and your object id recorded in the secrets file (`TASKS_GROUP_ID`, `TASKS_ASSIGNEE_ID`) | the run | once |
| The plan `ASSISTANT_TASKS_PLAN` in that group and the buckets `ASSISTANT_TASKS_TENANTS` | the run (assistant module, as the agent's account) | once, then verified |
| The bot's Entra app, Azure bot, hostname, Teams package; upload and `/sethome` | the run; the upload is yours (1.5) | once |

Without `AZURE_MANAGE`: create the group yourself with the agent's account as a
member, and put the group's id and your object id into the secrets file under
the two names above.

```bash
BOTS="secretary search news github admin tasks"
BOT_TASKS_CHANNELS="teams email"
BOT_TASKS_MAIL_ALIAS="tasks@example.com"                  # an alias on the agent's mailbox; the run makes the rule and folder
BOT_TASKS_MCP="tasks"
BOT_TASKS_TOOLSET="memory session_search clarify cronjob"  # no terminal: Planner only through its tools
ASSISTANT_TASKS_ENABLED=true
ASSISTANT_TASKS_GROUP="Acme Tasks"                        # the Microsoft 365 group; a Team too with ASSISTANT_TASKS_TEAM=true
ASSISTANT_TASKS_PLAN="Tasks"
ASSISTANT_TASKS_ASSIGNEE="you@example.com"                # owner of the group, assignee of every card
ASSISTANT_TASKS_TENANTS="Secretary,Acme,Globex"           # initial buckets; more on your word
BOT_SECRETARY_MCP="m365 google tasks"                     # the Secretary files deadlines as cards in its own bucket
```

The bucket named like the Secretary is where that bot puts every deadline it
reads off a letter or an invoice (start: the document's date; due: the
deadline; amount and reference in the notes) — so the Tasks bot's morning
digest, a `cronjob` at 07:00 it sets up on first contact, covers them too.
Planner sends no reminders of its own; the digest and one-shot reminders at
a time of day ("erinnere mich am 12.9. um 14:00 …") are the alarms, delivered
as Teams messages — a push on the phone.

Existing cards in another plan: Planner's API cannot move a card between
plans. Recreate the few that matter through the bot ("Acme neuer Task …"),
or move them in the Planner app, then delete the old plan.

`tasksctl` (in `/usr/local/lib/hermes-assistant`) shows the plan and its
buckets (`status`, `tenants`) and what is due (`due`, `digest`); the Admin bot's
snapshot carries `tasksctl status`.

---

# PART 2 — Fill the configuration

## 2.1 · The five files

```
config/
  bootstrap.conf     tracked    which account the agent gets            ← structure
  install.conf       tracked    tool catalogue, git behaviour, CLIs     ← structure
  hermes.conf        ignored    host, service, inference, tunnel, relay ← your site
  channels.conf      ignored    which channels, allowlists, policy      ← your site
  secrets.conf       ignored    every token and password, mode 0600     ← your secrets
  credentials/       ignored    files deployed verbatim (the SSH key)
```

Start from the templates:

```bash
cp config/hermes.conf.example   config/hermes.conf
cp config/channels.conf.example config/channels.conf
cp config/secrets.conf.example  config/secrets.conf
chmod 0600 config/secrets.conf
```

Each template has a **SITE VALUES** block at the top. Fill that block plus the
secrets file, and you are done — everything below those blocks has a working
default and a comment saying why.

## 2.2 · The three names behind every credential

This trips people up once, then never again:

```
channels.conf   CHANNEL_EMAIL_ALLOWLIST_VAR="EMAIL_ALLOWED_SENDERS"   ← only the NAME
      │
      ▼
secrets.conf    EMAIL_ALLOWED_SENDERS="you@example.com"               ← the VALUE
      │
      ▼
.env            EMAIL_ALLOWED_USERS=you@example.com                   ← what Hermes reads
```

`channels.conf` never holds a value, which is why it can be read by anyone who
can read the repository. The last name is the vendor's and is not yours to
choose. The middle one is.

**Allowlists are comma-separated.** Every adapter splits on `,` — verified in
the telegram, email and teams adapters. Written with spaces, two entries become
one token that matches nobody; the gate fails closed, so it is safe and
completely silent: the second person never gets a reply and nothing says why.
The run normalises either spelling to commas before writing, but write commas.

**Unknown senders are ignored, explicitly.** The agent's default for
`unauthorized_dm_behavior` is `pair`, not `ignore` — a stranger who finds the
bot is handed to a pairing handshake. The run sets `ignore` on every channel it
enables. A disabled channel is set to `enabled: false` in the agent **and its keys are
removed from `.env`**, not merely skipped; an earlier version skipped it and the
platform kept running — with a bot token still on disk — while the
configuration claimed otherwise.

## 2.3 · Check it before touching the host

```bash
./install.sh --dry-run
```

This changes nothing, downloads nothing and costs no API budget. It ends with
`dry run complete — nothing was changed`. Until every declared credential is
present it refuses by name instead:

```
error configuration is not valid:
error   - DEVTOOLS_GITHUB_TOKEN_VAR names 'GITHUB_TOKEN', which is empty in SECRETS_FILE
error refusing to change anything until the configuration is fixed
```

---
---

# PART 3 — Install

## 3.1 · `bootstrap.sh` — give the agent its own account

Run this **from your own account, with `sudo`** — it reads `SUDO_USER` to copy
your `authorized_keys` across.

```bash
sudo ./bootstrap.sh          # add --dry-run first if you want to see it
```

It is idempotent and does, in order:

```
  account         create it, or adopt an existing one
  home            move it to /home/<account> if it sits somewhere unsuitable
  shell           give it /bin/bash        ← the CLIs sign in through a login shell
  sudo            add to the sudo group + a NOPASSWD drop-in
  ssh             copy your authorized_keys
  repository      rsync -a --delete  <this repo>/  →  /home/<account>/setup-hermes-agent/
```

> **After bootstrap, the copy in the account's home IS the repository.** Work
> there, as that account (`sudo -u hermes -i`), and delete the copy you
> bootstrapped from — two copies are two places for the truth to drift. Run
> from inside it, `bootstrap.sh` skips the copy step and only converges the
> account itself. On a rebuilt host: clone anywhere, bootstrap once, delete.

## 3.2 · `install.sh` — the run

Before the first run, with `AZURE_MANAGE=true`: sign the Azure CLI in **as the
account that runs the installer** — the session lives in that account's
`~/.azure`, and the run (root under `sudo`) uses the invoking user's profile.

```bash
az login --use-device-code --tenant <AZURE_TENANT_ID>
```


```bash
sudo -u <account> -i
cd setup-hermes-agent
sudo ./install.sh 2>&1 | tee /tmp/install.log
```

Modules run in this order, and the order encodes real constraints:

```
  preflight    platform, resources, ports, egress
  host         timezone FIRST — everything scheduled depends on it
  credentials  deploy config/credentials/ into the account
  git          identity, known_hosts, ssh config, https→ssh rewriting
  tunnel       Cloudflare API: tunnel, DNS, ingress, daemon
  docker       only if the container sandbox is enabled
  devtools     the catalogue, into /usr/local/bin
  clis         the subscription CLIs, as the service account
  mailproxy    the OAuth relay
  agyshim      the inference bridge          ← before the gateway that talks to it
  hermes       the vendor installer, at the pinned revision
  service      systemd unit + drop-ins
  channels     providers, allowlists, approval policy
  dashboard    loopback UI behind an authenticating proxy
  backup       timer
```

Expect several minutes: 17 apt packages, 28 downloaded binaries, two Python
virtualenvs and the vendor installer.

## 3.3 · The sign-ins that cannot be scripted

All need a browser. None can be automated, and the run tells you so rather
than pretending otherwise.

**a) The inference CLI**

```bash
sudo -u <account> -H agy
```

The `-H` matters: credentials are per-account and live in that account's home.
A sign-in performed by an administrator does not carry over — that is the usual
reason a CLI works interactively and then fails as a service.

> Its own installer puts the binary in `~/.local/bin`, which is fine. systemd's
> default `PATH` stops at `/usr/local/bin`, so the unit records the **absolute**
> path rather than depending on a `PATH` the service never has.

**b) The mail relay**

The relay starts without a token and prints a URL and a code the first time it
is used. The run stops there with the exact command:

```bash
journalctl -u <service>-mailproxy -n 50
# open the URL, enter the code, sign in as the agent's work mailbox
sudo ./install.sh 2>&1 | tee /tmp/install.log     # second run, now complete
```

It happens once. The relay stores a refresh token and renews it by itself.

**c) The assistant (Microsoft 365)**

With `ASSISTANT_M365_ENABLED=true` the run itself prints a URL and a code and
waits (up to `ASSISTANT_LOGIN_TIMEOUT` seconds). Open the URL in a **private**
browser window and sign in as the agent's mailbox account. The run refuses a
token that belongs to anyone else and stores nothing in that case. The token
lives in `/var/lib/hermes-assistant/m365.token` (0600, the agent's account) and
renews itself. `m365ctl` (in `/usr/local/lib/hermes-assistant`) runs the server's
commands with its environment: `status`, `login`, `ensure-folder`, `check-mailbox`, `tools`.

**d) The assistant (Google), and every read account**

The Google sign-in is a paste-back: the run prints a URL, you open it **as the
agent's Google account**, consent, and paste back the address of the page you
land on (an unreachable `127.0.0.1` page — that is expected). Every address in
`ASSISTANT_GOOGLE_READ_ACCOUNTS` repeats this once, **as that account**, with
read-only scopes. Without a terminal the run names the command instead:
`googlectl login [account]`.

> **Plan for two runs.** The first installs everything and stops at the relay;
> the second converges. That is cheap, because everything already done is
> skipped — the second run is also the real test of idempotency and should be
> almost entirely `--` lines.

---
---

# PART 4 — Verify

```bash
systemctl status <service>                      # the gateway
systemctl status <service>-bridge               # inference bridge
systemctl status <service>-mailproxy            # mail relay
systemctl status <service>-dashboard            # the web UI — its OWN process
systemctl status cloudflared                    # tunnel
systemctl status nginx                          # the authenticating proxy

curl -s http://127.0.0.1:8787/v1/models         # the bridge answers
journalctl -u <service> -f                      # follow the agent
```

Then the thing that actually matters — send it a message on each channel, and
send one from an address that is **not** on the allowlist and confirm it is
ignored.

```bash
tests/run.sh                                    # everything that does not touch the host
tests/devtools-urls.sh                          # release URLs still resolve (needs network)
```

---
---

# PART 5 — Day to day

```bash
./install.sh --dry-run           # preview; changes nothing, downloads nothing
sudo ./install.sh                # converge
sudo ./install.sh --uninstall    # remove service and code, keep the agent's state
sudo ./install.sh --uninstall --purge   # also remove state and the account
```

**Running part of it.** A full run touches every module, and the cloud-side
ones (Azure, tunnel, developer tools, Google) spend most of the time asking
APIs whether anything changed. After a role, provider or channel change, name
what you need:

```bash
sudo ./install.sh --only channels,assistant      # preflight always runs first
sudo ./install.sh --skip azure,tunnel,devtools   # everything but the slow cloud checks
./install.sh --list-modules                      # the names, in run order
```

Modules run in their canonical order whatever order you name them. A named
module must find what the earlier ones installed; a missing prerequisite is an
error, not a fallback — `--only channels` on a host with no agent fails and says
so. Every run ends with the time each module took, slowest first, so a slow
module has a name to put in `--skip`. A bot is restarted at most once per run:
a role change hands its restart to the channel pass, and anything still owed
is restarted at the end.

**Upgrading.** Raise `HERMES_REF` in `config/hermes.conf`, mirror, re-run.

> **Never run the agent's own updater.** It checks the tree back out onto the
> default branch and drops the pin. The approval denylist blocks the agent from
> doing it to itself.

**Changing anything.** Edit in the repository under the service account's home,
run `tests/run.sh`, then `sudo ./install.sh` from there. There is no mirror step
in daily work; `bootstrap.sh` is for bringing up a fresh host.

**Switching a bot's model.** Comment one `BOT_<KEY>_LLM_*` block, uncomment
another (the examples carry a `custom` endpoint and a hosted provider), make
sure the key it names is in the secrets file, run `sudo ./install.sh`. The run
rewrites that profile's model, puts the key into its `.env` and restarts that
bot only. Its sub-agents keep the endpoint `BOT_<KEY>_DELEGATION_ENDPOINT`
names, whatever the bot itself runs on.

**Adding a mailbox the Secretary may read.** Append the address to
`ASSISTANT_M365_READ_MAILBOXES` (Exchange, same tenant — then the delegation in
the admin center, 1.10) or `ASSISTANT_GOOGLE_READ_ACCOUNTS` (a Google account —
then one sign-in as that account, 1.11), run the installer. Removing an address
removes the parameter value from the tools on the next run; the token file or
delegation can be deleted by hand.

**What a converged run looks like.** Run the installer twice; the second run
must end with

```
ok  done — already in the desired state, nothing changed
```

and show no `wrote`, `set`, `restarted` or `created` line — only `--` entries.
Measured on the reference host with every module on, Azure and Cloudflare
included: 79 unchanged, 0 changes. Anything else is a bug in a module, not a
property of the host.

**A converged run restarts nothing.** Every service unit — bridge, relay,
dashboard, gateway — is brought up through one helper that restarts only if the
module that owns it changed something, and otherwise just makes sure it is
running. Before that, five modules restarted their service on every run and
each restart counted as a change that restarted the gateway as well: a live
agent interrupted by a provisioner that had nothing to do. The tunnel's ingress
is read before it is written for the same reason.

**Files with two authors.** `config.yaml`, the relay's configuration and the
vendor's systemd unit are all written by something other than this provisioner
as well. For each, the run decides which lines are its own, compares only
those, and never rewrites while the other author is running. Every "changed on
every run" this installer ever had came from forgetting one of those three.

**After a reboot.** Every unit is enabled: tunnel, relay, bridge, one gateway
per bot, the dashboard, nginx, the backup timer. A bot unit is ordered after
the bridge and the relay (`Wants`, not `Requires`), and its start timeout is
`SERVICE_START_TIMEOUT` (300 s) because a cold boot starts every gateway at once.
Nothing needs a sign-in again: tokens, the tunnel credential and the CLI's
login live on disk. Check with

```bash
systemctl list-units --type=service --state=failed
for u in cloudflared hermes-gateway-mailproxy hermes-gateway-bridge; do systemctl is-active $u; done
systemctl is-active '<service-prefix>-*'      # the bots
```

and one message per bot in Teams. A relay that answers its first IMAP poll with
`EOF` is the known hiccup and self-heals.

**Letting something other than this host reach the bridge.** It answers on
loopback and checks nothing, which is safe only because the kernel refuses
everyone else — the endpoint spends your subscription for whoever reaches it.
Set `AGY_SHIM_AUTH=true` and the run mints a token into the secrets file, drops
it into a 0600 file the service reads, and requires it on `/v1`; `/healthz`
stays open so a probe still works. Every caller must then name the secret
(`LLM_ENDPOINT_1_TOKEN_VAR="AGY_SHIM_TOKEN"`), and the run refuses to start
before that rather than after. Only with a token will the bridge bind an
address other than `127.0.0.1`.

**Why the first message to a bot after a run is slower.** The bridge keeps one
CLI process warm per bot, because starting one costs about 2.3 seconds of a
turn (measured: a short question answered in 3.5 s cold and 1.2 s warm). A
restart empties that shelf, so the first message to each bot pays the start and
the next ones do not. `AGY_SHIM_MAX_SPARES` sets how many are held — one per
bot is the point of it, each holds roughly 200 MB, and `0` switches it off. The
count is in the bridge's `/stats`.

**Where the bots write.** Each bot's terminal starts in its profile's `work/`
directory and its `TMPDIR` points to `work/tmp`; the shared persona says so and
tells the bot to remove what it made. A tmpfiles rule
(`/etc/tmpfiles.d/hermes-provisioner.conf`, systemd's daily clean) removes files
older than two days from every `work/` and older than a day from the download
folders the assistants create for photos and scans. The bridge removes working
directories that earlier processes left behind when it starts. What a model
puts elsewhere by name (a venv in `/tmp`, a clone) is the model disobeying its
persona — worth a word in its role, not a rule here.

**Backups.** A timer runs `hermes backup` — consistent SQLite snapshots, not a
`tar` of a live directory. Restore is manual and needs the gateway stopped; the
procedure is in `docs/runbook.md`, and it has to be rehearsed before you need it.

---
---

# PART 6 — Troubleshooting

Each of these was hit for real during a first installation.

### The run produces no output at all

Fixed, but know the shape: `exec {fd}>file 2>/dev/null` applies the redirection
to the **shell**, permanently — silencing every subsequent log line, since all
logging goes to stderr. If a run ever goes quiet, that is the shape to look for.
Two unit tests now guard it.

### `Cloudflare API rejected GET /user/tokens/verify: Invalid API Token`

The token is fine. That endpoint only describes **user-owned** tokens and
rejects account-owned ones — and an account-owned token is what carries the
`cloudflared` connector permission. Current versions verify by exercising the
permissions instead. If you see this, your copy is behind the origin.

### `no edge certificate for <hostname>` / TLS `alert handshake failure`

A proxied hostname is terminated by Cloudflare's edge, and the edge needs a
certificate for the zone (Universal SSL). Without one, **every** TLS handshake
to **every** name in the zone fails with alert 40 — the tunnel itself is fine,
its request counter just never moves, the Bot Framework reports 502 to whoever
sends, and Teams shows the bot offline. Seen from the host it looks exactly like
egress filtering, which is what it was mistaken for.

Dashboard: **SSL/TLS → Edge Certificates → Universal SSL → Enable**; issuance
takes minutes to an hour. When the run itself has just enabled it, it waits up
to `TUNNEL_EDGE_TLS_WAIT` (default 300 s) for the first handshake, then defers
the failure and finishes the rest of the installation; a later re-run completes
the check. With `Zone → SSL and Certificates → Edit` on the API
token, the run enables it itself and verifies the handshake afterwards.

### `cloudflared` restarts forever, `Failed to dial a quic connection`

The daemon's own precheck states the answer and then ignores it:

```
precheck  "TCP Connectivity: HTTP/2 connection successful"  status=pass
precheck complete   suggested_protocol=http2
ERR Failed to dial a quic connection ... Retrying in up to 4s ... 8s ... 16s
```

Its precheck also prints `SUMMARY: ... cloudflared will proceed using 'http2'`
and then does not — the precheck is advisory, the connection loop keeps dialling
UDP. Set the transport explicitly:

```bash
TUNNEL_PROTOCOL="http2"       # config/hermes.conf — "" | quic | http2
```

> **This has to be a command-line flag.** The `TUNNEL_PROTOCOL` environment
> variable is *recognised* — cloudflared logs it under `Environmental
> variables` — and then ignored; the next line still reads `Initial protocol
> quic`. The run therefore overrides `ExecStart` in a drop-in rather than
> setting an environment variable. `--protocol` no longer appears in
> `cloudflared tunnel run --help` as of 2026.8.x, but it still parses and still
> works.

The vendor unit is also `Type=notify` with `TimeoutStartSec=15`, shorter than a
first connection takes on such a network; the same drop-in raises it to
`TUNNEL_START_TIMEOUT` (90s default).

### `Failed to read token file: /etc/cloudflared/token`

`cloudflared service install` writes that file once, as a side effect. A service
killed during startup can come back with it gone, and the tunnel is then
unrecoverable without another API call. The run now writes the file itself, on
every run, as an invariant.

### `GitHub API rate limit` / `could not resolve a release for …`

42 lookups against 60 per hour per IP. Set `GITHUB_TOKEN` (§1.7). The run checks
the budget **before** the first download and fails by name rather than half way
through the catalogue.

### `account '<name>' has shell '/usr/sbin/nologin'`

The account exists but cannot host the agent: the CLIs are installed and signed
in through a login shell, and `HERMES_HOME` derives from the home directory.
`bootstrap.sh` fixes both. The run also refuses when the home directory
disagrees with `bootstrap.conf`, because it would configure one location while
the agent reads another.

### `The relay did not complete the login`

Not a password problem — the relay accepts any loopback login and authenticates
upstream with OAuth. It has no token yet. See §3.3b.

### The run seems to hang with no output

Check whether a child process was *stopped* rather than stalled:

```bash
pgrep -af 'install\.sh'
ps --ppid <that pid> -o pid,etime,stat,args
#   STAT "T" = stopped, not busy
sudo kill -CONT <the stopped pid>
```

A `Ctrl+Z` in the terminal suspends the foreground process group, and a long
`apt-get` is the usual victim. The provisioner is waiting on a child that will
never return, so it prints nothing — which looks identical to a hang. `fg` in
the original shell does the same thing.

### `User is authenticated but not connected.`

Exchange Online says this *after* accepting the OAuth token, so the relay, the
app registration and the sign-in itself are all working. Two different causes
produce it, and they are worth checking in this order:

**1 · The token belongs to the wrong account.** The device flow authorises
whoever the browser is already signed in as — it never asks which account you
mean. Sign in while another session is open and the relay ends up holding a
perfectly valid token for a mailbox that is not the agent's, which is exactly
what this message describes. This was the real cause on the first installation,
and it cost hours because the message reads like a settings problem.

```bash
sudo systemctl stop <service>-mailproxy      # stop it FIRST — see below
sudo rm /var/lib/hermes-mailproxy/emailproxy.config
sudo ./install.sh                            # regenerates, then prints a new code
```

Open the URL in a **private window** and sign in explicitly as the agent's
mailbox. Order matters: delete the file while the relay is running and it
writes its in-memory token back out on shutdown, so the next run reports
`the relay holds a refresh token; no sign-in needed` and nothing has changed.

**2 · IMAP is switched off for the mailbox.** A per-mailbox setting that blocks
OAuth sessions too, independently of the tenant-wide basic-authentication
switch.

```
Microsoft 365 admin center  →  Users  →  Active users  →  <the agent>
  →  Mail  →  Manage email apps  →  tick IMAP  (and Authenticated SMTP to send)
```

or, in Exchange Online PowerShell:

```powershell
Set-CASMailbox -Identity <the agent> -ImapEnabled $true `
                                     -SmtpClientAuthenticationDisabled $false
```

Changes take up to an hour to reach every front end. If the **Mail** tab offers
no email apps at all, the account has no Exchange Online mailbox — a licence
question, not a settings one.

### `bot … exists with a different identity` — app and tenant SWAPPED

The Azure Bot was created by hand with the tenant ID in the app field and vice
versa. It looks fine in the portal — both are GUIDs — and fails silently: the
Bot Framework cannot authenticate, so it never posts to the endpoint, and Teams
shows the bot offline. The tunnel's request counter stays at 0 no matter how
many messages you send.

`msaAppId` cannot be changed. Set `AZURE_BOT_RECREATE=true` in
`config/hermes.conf`, run once (the bot is deleted and recreated from
`src/azure/bot.bicep`), set it back to `false`, and add the Teams app to a chat
again.

### E-mails from you are ignored — `Dropping sender with unauthenticated From`

The adapter trusts `From:` only when the receiving server stamped an
`Authentication-Results` header (SPF/DKIM/DMARC pass). Exchange Online stamps
it on inbound external mail but **not on mail between two mailboxes of the same
tenant**, so an operator writing from the same tenant as the agent's mailbox is
dropped every time. Set `CHANNEL_EMAIL_REQUIRE_AUTHENTICATED_SENDER=false` in
`config/channels.conf` and rerun. The allowlist still applies; the risk you
accept is a spoofed `From:` that Exchange's own anti-spoofing lets through.

### `platform 'teams' has no valid toolsets configured (unknown name(s): hermes-teams)`

The pinned release ships a default configuration naming a toolset it does not
define, so Teams ran without tools (upstream issue #38798). The installer sets
`platform_toolsets.teams` to `CHANNEL_TEAMS_TOOLSET` / `BOT_<KEY>_TOOLSET`
(default `hermes-telegram`, the core set; or a list of toolsets) and refuses a
name that the installed `toolsets.py` does not define.

### `named custom provider 'bridge' has no resolvable api_key` on every turn

The agent's auxiliary client resolves the provider's `key_env` itself and warns
when the variable is missing — and also when it equals the agent's own
placeholder `no-key-required`. The bridge never reads the `Authorization`
header, so the installer writes a marker value (`bridge-does-not-check-keys`)
into `.env` for keyless custom endpoints.

### `No home channel is set for Teams`

The home channel is where cron results and cross-platform messages land. Its
identifier is the Teams conversation id, which exists only after the first
message, so it is set from the chat: type `/sethome` once in the bot chat. The
agent stores it under `platforms.teams.home_channel`; the installer's merge
keeps keys it does not manage, so it survives every later run.

### Mail stopped after a run that granted consent — `AUTHENTICATE failed`

Admin consent writes one grant per API with exactly the scopes the app
**declares**, replacing what was there — including the per-user grant the
relay's device-code sign-in had created for `IMAP.AccessAsUser.All` and
`SMTP.Send`. The installer therefore declares the relay's Exchange scopes
(`MAILPROXY_SCOPES`) together with the assistant's Graph scopes and consents
once for both; it re-reads the grant after consenting, because a declaration
made seconds earlier may not have replicated yet. The relay then still holds
its cached access token for up to an hour; the mail probe drops it once
(`mailproxy_force_refresh`) when a login through the relay is refused.

### `assistant: the M365 sign-in for … did not complete`

The run printed a URL and a code and waited `ASSISTANT_LOGIN_TIMEOUT` seconds.
Run it again and enter the code in time; sign in as the mailbox account named in
`ASSISTANT_M365_ACCOUNT`. `signed in as X, but this token must belong to Y`
means the browser carried another identity — use a private window.

### The run waits at `Pasted address:`, the paste does nothing, Ctrl-C does not abort

Seen with `sudo-rs` and `Defaults use_pty` (Ubuntu's default): every `sudo`
gets its own pseudo-terminal, and a sign-in started as `sudo -u <account>`
inside `sudo ./install.sh` read its `/dev/tty` on a terminal your keyboard never
reached. The run now starts the servers' commands with `runuser`, which adds no
terminal. If a run is stuck there: from a second terminal
`sudo kill "$(pgrep -f 'google_assistant.py login')"` — the run then records
the sign-in as pending and finishes. Do the sign-in by hand (1.11, the
`sudo -i` + `runuser` form) and re-run.

### `Provider authentication failed` right after switching a bot to a hosted provider — log says `HTTP 401: Missing Authentication header`

The profile's `config.yaml` still carried the vendor's default `model.base_url`
(the aggregator), and for a hosted provider an explicit `base_url` wins over the
provider's own address — so the bot sent keyless requests to the wrong host.
Since 2026-09-07 the run writes `base_url` with every model block (empty for a
hosted provider); re-run the installer and the bot restarts on the right
address. Check with `grep -A3 '^model:' <profile>/config.yaml`.

### The Secretary says a path "is under Secretary/ but not in one of its worlds" or "file names … end with '_bus'"

Working as designed: `ASSISTANT_M365_WORLDS` is set and the drive tools refuse
a misfiled document with the corrected name. The model normally retries with
that name; if it keeps failing, the request itself named a path outside the
worlds — say "business" or "private", or give the full path.

### A pasted link arrives as a name; the Secretary cannot open a SharePoint file

Two causes, both handled. Teams renders a pasted URL as a named link and puts
the URL only into the `text/html` attachment it mirrors on every message; the
adapter skipped that attachment. The run carries a patch (like the e-mail
folder one) that appends the missing hrefs to the text as `(link: …)`, and the
bots restart once after it is applied. And a SharePoint or OneDrive link needs
the tenant's access: the web tools have none, so the Secretary opens such links
with `m365_share_read` (text of a PDF or Word file) or `m365_share_download`
(photos, scans) through Graph's sharing endpoint — the scope `Files.Read.All`
is declared and consented by the run for it. Links the agent's account cannot
open (not shared with it) fail with Graph's own `accessDenied`.

### The balance line says `unbekannt`

The proxy could not reach the provider's balance endpoint with the bot's key:
`journalctl -u <service>-balance-deepseek` names the reason. The answer itself
was delivered; the balance is fetched again after `API_PROXY_CACHE` seconds.

### `assistant: the M365 token does not carry Tasks.ReadWrite yet`

The scope was declared and consented in this run (or the azure module has not
run at all, `AZURE_MANAGE=false`); the assistant's token was issued before
that and is refreshed once by the run — when the grant has not replicated
yet, the refreshed token still lacks the scope. Wait a few minutes and run
`sudo ./install.sh --only assistant`; `m365ctl status` shows the scopes the
token carries.

### `Planner refuses to create the plan (HTTP 403)` / `assistant: could not ensure the plan`

The agent's account must be a member of the group, and Planner learns of a
membership minutes after the directory has it. The run added the account in
the azure module of the same run; run `sudo ./install.sh --only assistant`
again a little later. Still 403 after an hour: check in the Microsoft 365
admin center that the group lists the agent's account as a member.

### The bot says `no tenant named …`

Tenants are the plan's buckets, matched by name regardless of case. A new
customer is a new bucket, which the bot creates only on your explicit word
("ja, neuer Tenant") — or add it in the Planner app; the bot sees it on the
next call.

### `assistant: the mailbox … is not readable by … yet`

The Exchange delegation is missing or not applied yet. Sign in to the Exchange
admin center as a tenant admin, open the mailbox, *Delegation → Read and manage
(Full Access) → Add* the agent's account, wait up to an hour, re-run. Check by
hand with `m365ctl check-mailbox <address>` as the agent's account; the reason
it prints is Graph's own (`ErrorAccessDenied` = no delegation, `ErrorInvalidUser`
= no such mailbox in the tenant). The scope side (`Mail.Read.Shared`) is
declared and consented by the run — if `m365ctl status` does not list it, the
azure module has not run with `AZURE_MANAGE=true` since the mailbox was added.

### `account … is not one the assistant may read` / `mailbox … is not one the assistant may read`

The model asked for a mailbox that is not in `ASSISTANT_M365_READ_MAILBOXES`
or `ASSISTANT_GOOGLE_READ_ACCOUNTS`. The servers refuse before asking Graph or
Google; add the address to the list and re-run, or tell the bot which mailbox
you mean.

### `google: OAuth client not in the secrets file`

The one manual Google step. Console → Google Auth Platform (project from
`GOOGLE_PROJECT`) → Clients → Create client → Desktop app; put id and secret into
the secrets file under the names the message gives, rerun.

### `Google issued no refresh token` / token refresh fails after a week

The OAuth app is still in *Testing*. Google Auth Platform → Audience → Publish
app, then `sudo -u <account> /usr/local/lib/hermes-assistant/googlectl login`
once more.

### `admin consent failed`

The `az` account is not allowed to consent for the tenant. Sign `az` in as a
Global Administrator (or Privileged Role Administrator), or grant consent once
in Entra → App registrations → Hermes Mail → API permissions → *Grant admin
consent*, then rerun.

### The agent says it cannot reach mail or calendar

```bash
sudo -u <account> /usr/local/lib/hermes-assistant/m365ctl status
```

`ok: true` with the right account means the token works and the problem is on
the agent's side: check that `mcp_servers.m365.enabled` is `true` in
`config.yaml` and that the gateway log shows the server's tools at start-up.

### Meeting roles were not applied

`co-organizer` needs an account of the same tenant; a guest can only be a
`presenter`. The result of `m365_event_create` carries a `roles` object that
says what happened.

### Teams shows the bot as offline

Work outward from the host; each step rules out a layer.

1. **Is the webhook up?** `curl -s -o /dev/null -w '%{http_code}\n' -X POST
   http://127.0.0.1:3978/api/messages` — **401** means the Teams SDK is
   listening and validating JWTs. The gateway logs only failures; a silent
   start after `Started hermes-gateway.service` is a successful one.
2. **Did the gateway give up waiting?** `journalctl -u <service> | grep 'teams
   connect timed out'`. The platforms connect inside one 30-second budget, and
   the e-mail adapter's IMAP login is synchronous in the event loop. While the
   relay is waiting for a device-code sign-in, that login blocks for the whole
   budget and Teams never gets its turn — the log then shows both failing at
   the same second. Finish the mail sign-in and restart; Teams comes up with it.
3. **Has Microsoft ever reached you?** Do not read the cloudflared journal for
   this — at its default log level it does not log individual requests, and an
   empty grep proves nothing. Read the daemon's own counter instead:

   ```bash
   curl -s http://127.0.0.1:20241/metrics | grep cloudflared_tunnel_total_requests
   ```

   `0` after you have sent the bot a message means the Bot Framework is not
   posting to this hostname at all. Then, in Azure: Bot → **Configuration** →
   Messaging endpoint must be exactly `https://<TUNNEL_HOSTNAME>/api/messages`,
   and **Channels** must list Microsoft Teams. Send another message and watch
   the counter; the moment it moves, the rest of the chain is being exercised.
4. **Prove delivery without Teams.** `tests/bot-delivery-probe.sh [key]` posts an
   activity through Direct Line — the same Bot Framework delivery path Teams
   uses — and watches the tunnel counter. `DELIVERED` plus
   `Unauthorized user: probe () on teams` in the gateway log means Azure, the
   edge certificate, the tunnel, the gateway and the Teams SDK's JWT check all
   work, and the allowlist did its job. If that passes and a Teams message
   still does not arrive, the chat is bound to a stale bot (typically one that
   was deleted and recreated): start a fresh chat via
   `https://teams.microsoft.com/l/chat/0/0?users=28:<TEAMS_CLIENT_ID>`.
5. Only then look at the tunnel: `https://<TUNNEL_HOSTNAME>/` from a browser
   outside the host should answer **404** (the catch-all). This host itself may
   not be able to reach Cloudflare's edge on 443 even while the tunnel works —
   it uses port 7844 outbound — so test from your own machine.

### The dashboard answers `502 Bad Gateway`

The web UI is **its own process**, not something the gateway serves:

```
hermes dashboard        Start web UI dashboard (port 9119)
```

A 502 means the proxy is up and that service is not. There is no environment
switch that makes the gateway host it — an earlier version of this provisioner
wrote `HERMES_DASHBOARD=1` into the agent's `.env`, which is not a setting this
software reads; the run now removes that key if it finds it.

```bash
systemctl status <service>-dashboard
journalctl -u <service>-dashboard -n 40
```

The first start builds the web assets with npm and takes a minute or two.

### The dashboard answers `400 Invalid Host header`

```json
{"detail":"Invalid Host header. Dashboard requests must use the bound hostname
 or the configured public hostname."}
```

The UI validates the `Host` header, and it validates WebSocket `Origin` the same
way. Rewriting `Host` in the proxy gets past the first guard and fails the
second — the UI streams, so it would reconnect in a loop instead of failing
outright. Tell it its public address instead; the run writes this into
`/etc/hermes-dashboard.env` (mode 0600, because unit files are world-readable):

```
HERMES_DASHBOARD_PUBLIC_URL=http://<bind>:<port>
```

Setting a non-loopback public URL also engages the dashboard's own
authentication, which is right: once it answers on a routable address it should
not depend on the proxy in front of it for its security.

### A question with options arrives as one run of prose

Teams joins lines that are separated by a single newline, and the agent's
fallback for a multiple-choice question is an indented numbered list — so
question, options and instruction arrive as one paragraph, unreadable on a
phone. The run carries a patch that writes the options as a `- ` list with the
numbers kept; it is applied by the `hermes` module and needs the bots
restarted, which the run does. Check it is in place:

```bash
grep -c 'setup-hermes-agent: readable choices' <install dir>/gateway/platforms/base.py
```

Answer such a question with the number, the option's text, or your own words —
that works on every channel, with or without the patch.

### The bot answers an earlier question — the same answer to everything you ask

Not repetition: the model is answering the loudest thing in the request, and
your question is not it. A stateless request carries the whole chat (ADR 0021),
so one research-heavy turn can leave a hundred entries of scraped page behind
it, and the question is a single line at the end of 150k tokens. Mid tool loop
it is worse — the last message is a tool *result*, so nothing at the end even
names what is being answered.

What it looks like in the journal, and what to compare:

```bash
journalctl -u <service>-bridge | grep stateless | tail       # history=NNN sent=NNN in=NNN
journalctl -u <bot-service> | grep 'conversation turn'       # history=NNN msg='…'
```

Since bot 0.4.x the bridge caps the transcript (`AGY_SHIM_HISTORY_BUDGET`,
120000 characters; `0` sends everything), labels it `BACKGROUND ONLY`, heads the
live message with `=== THE MESSAGE TO ANSWER NOW ===`, and restates the user's
request on a tool-result turn (ADR 0026). If `history=` keeps climbing into the
hundreds within a day, the cause upstream of that is usually the bot's toolset:
a bot with a terminal researches with `curl | grep`, one page per turn — see
"Which toolsets a bot gets" in §Day to day, and `/reset` in the chat to drop a
transcript that is already poisoned.

### The bot answers as the vendor's coding assistant, or "forgets" its role

The bridge is stateless since bot 0.2.x (ADR 0021): every request is a fresh
CLI conversation carrying the whole context, with the bot's name placed right
before the user's message. If a bot still introduces itself wrongly, check the
bridge's `/stats` says `"mode": "stateless"` and that the profile's `SOUL.md`
begins with the bot's display name — the name is read from its
`Your name is **…**` line.

### `The model provider failed after retries` — bridge log says `improperly formatted function call`

This is the failure the native tool channel was built for (ADR 0024). The
model wants to call functions natively; when none are declared, the API
rejects every attempt, the CLI retries three times and the turn is lost. Since
bot 0.4.x the run registers the bridge's tools server with the CLI, so the
caller's functions ARE declared and the model calls them properly.

If you still see it, the channel is not in place. Check, in this order:

```bash
curl -s http://127.0.0.1:8787/stats | grep -o '"mode":[^,]*'   # want: …+native-tools
grep -o 'mcp(tools/[^)]*)' ~<account>/.gemini/antigravity-cli/settings.json
python3 -c 'import json;print(json.load(open("<home>/.gemini/config/mcp_config.json"))["mcpServers"].keys())'
sudo ./install.sh --only agyshim                                # writes both, then restarts the bridge
```

The bridge falls back to the text protocol when the CLI does not know the
server, and salvages a denied call's arguments when the allow rule is missing —
both keep answering, both cost turns. A bot whose transcript already taught it
the wrong channel is cleared with `/reset` in its chat.

### `The model provider failed after retries` — and the agent never acts

The CLI behind the bridge is an agent, not a model API. Asked for something
that needs work it reaches for its **own** tools, is auto-denied because
headless mode cannot prompt for permission, and returns nothing at all:

```
RuntimeError: jetski: no output produced — a tool required the "command"
permission that headless mode cannot prompt for, so it was auto-denied.
```

The bridge handles this by giving the CLI the caller's functions as real tools
(the `tools` MCP server, ADR 0024) and disabling its own; a completed call to
that server is the decision the gateway executes. So if you see this, neither
channel reached the model — check that the request actually carried tool
definitions:

```bash
journalctl -u <service>-bridge -f     # a served turn logs "N tool call(s)"
```

The division of labour is deliberate: the model decides, the gateway executes,
and the gateway's approval rules apply to every action. Letting the CLI run
commands itself would be less work and would put every command outside those
rules — see `docs/decisions/0017`, which also states what this costs.

### `[Email] IMAP connection failed: [SSL: WRONG_VERSION_NUMBER]`

TLS against a plaintext socket. The agent always speaks TLS to IMAP; the relay
must too — see §1.3. If the relay logs `Starting IMAP server … (unsecured)`,
the certificate lines are missing from its configuration.

### `[Email] IMAP fetch error: socket error: EOF` now and then

Sporadic — measured at 2 in ~15 minutes against 64 successful logins — and
self-healing: the gateway logs a "fatal" adapter error, reconnects seconds
later (`[Email] Connected as …`), and mail keeps flowing. Each drop coincides
with the relay logging `[SSL: WRONG_VERSION_NUMBER]` on its TLS listener, i.e. a
peer that spoke plaintext into it for an instant. No foreign client connects to
port 1993, `emailproxy` is current, and the agent's two IMAP connections are
both `IMAP4_SSL`, so the cause is inside that pair. Not blocking; if the rate
climbs, this is where to look.

### The relay's configuration keeps changing under you

It has two authors. The relay keeps its configuration in memory and **writes it
back on shutdown**, dropping comments (`configparser`) and adding token lines
of its own. Consequences the run now accounts for:

- It is **stopped before** its configuration is rewritten. A write while it runs
  is overwritten moments later by its own copy, in configparser's key order,
  with the additions missing — it looks as if the write never happened.
- Deleting the configuration to force a fresh sign-in only works with the relay
  **stopped first**; otherwise the token file reappears on shutdown.
- "Changed" is decided on the lines that are ours: not comments, not blank
  lines, not the token block.

### `--log-level debug` produced almost nothing

Fixed: the config file used to overwrite the flag, against the documented
precedence. A flag given on the command line now survives config loading.

### A tool fails to install

Upstream renamed a release asset. `tests/devtools-urls.sh` resolves every
download URL and reports which one 404s, without installing anything.

---

## Layout

```
install.sh        entrypoint: parse, validate, dispatch
bootstrap.sh      optional: create the account, mirror the repository into it
libs/             installer libraries, one per concern, numbered for source order
libs/azure/       Bicep: the Azure Bot and its Teams channel, deployed by 47-azure.sh
bot/              the bot's own code, versioned separately (bot/VERSION, bot/CHANGELOG.md, bot/release.sh)
bot/agy-shim/     the bridge between the agent and the inference CLI (agy_shim.py) and the caller's tools as an MCP server (tools_mcp.py)
deploy/           this repository as a unit of the onboarding platform: the consumer manifest, the Helm chart, the images (skeleton — see docs/decisions/0025)
bot/mcp/          the assistant MCP servers (Microsoft 365; Google; Tasks in Planner)
bot/teams-app/    Teams app manifest template and icons (rendered from bot/assets/ by render-icons.sh)
bot/build/        generated packages, gitignored
config/           documented configuration; the real files are gitignored
tests/            shellcheck, unit tests, acceptance cycle, agnosticism check
docs/             requirements, verified constraints, decision records, runbook
```

Libraries define functions and do nothing on their own, so tests can source
them. `install.sh` is the only thing that executes.

## Verification

```bash
tests/run.sh
```

Runs, in order: a syntax pass, `shellcheck`, the unit tests, the
site-agnosticism check, and a dry run against the example configuration.

The end-to-end cycle is separate, because it installs and removes a real service:

```bash
sudo tests/acceptance.sh --i-understand-this-is-destructive
```

It asserts what the rest cannot: install, install **again** and observe that
nothing changed and the service was not restarted, then uninstall and confirm
the agent's state survived.

`tests/agnostic.sh` is the one worth understanding. It builds a denylist from
the machine it runs on — current user, hostname, git e-mail, and the hosts in
your live config — and fails if any appear in tracked files. External hosts must
be listed in `tests/agnostic.allow`, so adding one shows up in review as a
deliberate change rather than passing silently.

A line may exempt itself from the URL, IP and e-mail checks with a trailing
`# agnostic-ok: <why>`. It exists for the tests that exercise those very checks
— a classifier test has to contain examples of what it classifies — and the
marker is grep-able, so an exemption appears in a review diff exactly the way an
allowlist entry does. It is not for silencing a real finding.

Install the tooling with `apt-get install bats shellcheck`; `gitleaks` is
optional and adds secret scanning.

## Documentation

| File | Contents |
|---|---|
| `docs/requirements.md` | Numbered requirements the tests gate on |
| `docs/constraints.md` | Verified facts the design rests on, with provenance |
| `docs/decisions/` | One record per decision, with its cost |
| `docs/runbook.md` | Upgrading, backups, restore, troubleshooting |

`docs/constraints.md` is the one to read before changing anything: several
obvious-looking assumptions about this software are wrong, and it says which.

## Security posture

The defaults encode a position, so it is worth being explicit:

- The service account **can become root**. The agent installs software, manages
  services and works across the host, and an account that cannot do that cannot
  do the job — see `docs/decisions/0016`. That makes everything below the
  boundary, not a supplement to it.
- **There is no container boundary.** The toolchain lives on the host and an
  agent inside a container cannot see it — `docs/decisions/0013`. What holds the
  line instead: mandatory allowlists, an approval denylist, unattended turns
  denied, scheduled-job approvals denied, and a single-purpose machine
  rebuildable from this repository.
- **The credentials on this host define the blast radius.** A cluster credential
  placed here is one the agent can use, and an agent reading untrusted mail can
  be argued into using it. Treat what you put here as what you trust it with —
  which is why §1.7 asks for a token with no scopes and §1.8 asks you to choose
  between an account key and a deploy key.
- **Allowlists gate who may talk to the agent, not what they say.** Message
  bodies — especially forwarded and quoted content — are untrusted input to a
  model that can send mail and run commands.
- The agent has **no calendar write access**. It proposes appointments as
  invitations you accept, which keeps the authorising step with you.

## License

MIT — see `LICENSE`. Configuration and secrets are yours and never part of the repository (`config/*` is ignored except the examples).

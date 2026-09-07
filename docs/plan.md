# Plan — the personal assistant, end to end

One configuration, one installer, one repository. Every item below is either
delivered by `install.sh` from this repository or is a one-time act by the
operator that the README describes step by step. Nothing is done by hand on a
host. Tick items here as they land; a second host must reach the same state
from `bootstrap.sh` + `config/` + `install.sh` alone.

Legend: `[x]` done and verified on the first host · `[ ]` open · `[?]` decision needed

## 1 · Foundation (done today)

- [x] Idempotent provisioner: a converged run reports "nothing changed" (79 skips, 0 changes)
- [x] Cloudflare tunnel over http2, Universal SSL / edge certificate verified
- [x] Azure Bot Service declared in Bicep, identity checked (swapped ids detected), Teams channel
- [x] Teams app package built from configuration (`build/hermes-teams-app.zip`), deterministic, python-only
- [x] Teams end to end: message → tunnel → gateway → bridge (agy) → answer in Teams
- [x] Teams allowlist by the operator's Entra object id (not the mailbox account's)
- [x] Teams toolset repaired (`hermes-teams` does not exist in the pinned release → `CHANNEL_TEAMS_TOOLSET`)
- [x] E-mail over the OAuth relay (TLS on loopback, cert in the system store), allowlist comma-separated
- [x] E-mail sender check made configurable (`CHANNEL_EMAIL_REQUIRE_AUTHENTICATED_SENDER`) — Exchange stamps no header on tenant-internal mail
- [x] Dashboard as own service behind nginx, login only once
- [x] Bridge (agy) with tool calling via the tool contract
- [x] Repository layout: `libs/` (installer libraries), `bot/` (the bot's own code: bridge, Teams app, MCP assistants), `bot/build/` gitignored
- [x] Bot versioning: `bot/VERSION`, `bot/CHANGELOG.md`, `bot/release.sh` (bump, date the changelog, tag `bot-v…`); the installer stamps the version and the Teams manifest carries it
- [x] Teams icons rendered from `bot/assets/appicon.svg` by `bot/assets/render-icons.sh` (PNGs committed; the installer needs no renderer)
- [x] Bridge key marker applied on the host
- [ ] Operator sends one mail from the work address and one from the private address in the allowlist → both answered
- [ ] Operator types `/sethome` once in the Teams bot chat (cron results and reminders land there)

## 2 · Assistant capabilities — Microsoft 365 (the M365 mailbox — `CHANNEL_EMAIL_WORK_ADDRESS`, the default)

Own MCP server in the repository (`src/mcp/m365_assistant.py`, Python, Graph REST), provisioned by a new
installer module (`assistant`) into a venv under `/var/lib/hermes-assistant`, registered under `mcp_servers`.

- [x] Sign-in: device-code flow as the M365 mailbox account, refresh token in `/var/lib/hermes-assistant/m365.token` (0600)
- [x] Entra: delegated scopes added to app "Hermes Mail" and admin-consented by the installer (`az`): Mail.ReadWrite, Mail.Send, Calendars.ReadWrite, OnlineMeetings.ReadWrite, Files.ReadWrite, User.Read, offline_access
- [x] Mail: search, read, reply, send (with attachments), move/archive, read attachment text
- [x] Calendar: view, find free slots, create / update / cancel events, invitations go out by mail automatically
- [ ] Teams meetings: event with Teams link; set roles — co-organizer (tenant users, e.g. the operator) and presenter (external guests) via `PATCH /me/onlineMeetings/{id}`
- [x] OneDrive: list, search, read (text of pdf/docx/txt), upload, move/rename, folders, share link
- [x] The Secretary's folder in the agent's OneDrive, created by the run and shared (edit) with the operator — `ASSISTANT_M365_ROOT_FOLDER`, `ASSISTANT_M365_SHARE_WITH`
- [x] Verification in the run: `whoami` over Graph, tools listed by the gateway, failure deferred (not fatal for other modules)
- [x] Tests: MCP protocol (tools/list schema), each tool's request shape against a fake Graph, text extraction, module bats
- [x] README part: what the assistant can do, how to sign in once, troubleshooting; ADR 0019

## 3 · Assistant capabilities — Google (the private Gmail account — `ASSISTANT_GOOGLE_ACCOUNT`, only when the operator says so)

Second MCP server (`src/mcp/google_assistant.py`), same module, same venv, own token.

- [x] Operator created the Google OAuth client (Desktop app, app published 2026-09-06) and puts `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` into `config/secrets.conf` — the run prints the steps; gcloud, login check and API enabling are the run's (module `google`)
- [x] Sign-in done 2026-09-06 (paste-back as the private Gmail account); refresh token in `google.token`, verified by the run
- [x] Gmail: search, read, reply, send, label/archive, attachment text (live: whoami, labels, drive verified)
- [x] Google Calendar: view, create (with Meet link) / update / delete (server written)
- [x] Drive: list, search, read (text), upload, move, folders, share (server written)
- [x] Tool descriptions and server instructions say: private account, only on request
- [x] Tests, README 1.11, verification in the run; Google tools registered in the Secretary profile

## 4 · Documents and reminders ("I hand over my letters")

- [x] Photo intake, host side: the bridge hands images to the CLI as files; a photographed letter is read (sender, amount, deadline) and the Secretary proposes the calendar entry with advance reminders and the filing place (verified 2026-09-05 with a test letter)
- [x] Photo intake, Teams side: operator sends a photo in the Secretary chat — verify the adapter's cached image reaches the same path (Secretary now on Kimi K3 with native image input) — verified 2026-09-06 (photographed letter via the Secretary chat)
- [x] Classification rules written down (invoice → due date + reminders 7 and 1 days before; appointment → event + reminder; information → file only) and adjustable in configuration — in bot/roles/secretary.md

- [ ] Intake paths: attachment to the M365 mailbox, file in the Teams chat, OneDrive folder `Assistant/Inbox` — all readable through the tools above
- [x] Text extraction for pdf / docx / txt (scanned PDFs without text: state the limit; OCR is a later toggle) — pypdf/python-docx in the assistants; scanned PDFs are reported as such
- [ ] Reminders: verify the cron toolset is available on Teams and delivers to the home channel; document the phrasing ("erinnere mich am …")
- [x] Filing: the agent stores processed letters in OneDrive folders it names, and returns the location — role rules + m365_drive_upload_file / share link
- [ ] Memory: dates and facts from letters survive session resets (Hermes memory toolset verified on Teams)

## 5 · Private and work separation

- [x] Routing rule (2026-09-05): business is the default and goes to Microsoft 365; "privat" / "privater Termin" / the Gmail account by name goes to Google. Written into both servers' instructions and tool descriptions so the model picks the right world itself
- [x] Decision (2026-09-05): one bot per role, each its own 1:1 chat in Teams (own Entra app, Azure Bot F0, Teams app, gateway service, tunnel hostname). Bots are a LIST in configuration — add, rename, remove later without code changes
- [x] Decision (2026-09-05): three bots to start — **Secretary** (appointments, meetings, invitations, reminders, invoices, hour reports, letters, translation — "I say what I want, it does it"), **Search** (phone numbers, addresses, coordinates as maps links, website analysis, reports), **News** (daily briefing across countries: war, technology, finance). Display-name prefix from `BOT_PREFIX`
- [x] Decision (2026-09-05): nothing user-visible is named "Hermes" — bot names, Teams apps, Entra apps, hostnames are ours; everything the operator writes in German is rendered in English in the product
- [x] Installer refactor: from one gateway to a bot list (`BOTS`), per bot: Entra app (created by `az`), Azure Bot via Bicep, Teams package, gateway service instance with its own profile (persona file under `bot/roles/<name>.md`, toolsets, MCP servers), port and tunnel hostname; shared assistant servers
- [x] Rename the existing pieces: the current bot became Secretary (`secretary.<zone>`, Entra app "<prefix> Secretary", Azure bot `<service-prefix>-secretary`); "Hermes Mail" stays an internal app name (not user-visible)
- [x] All three bots reachable end to end (Direct Line probe: Azure → edge → tunnel → own gateway → allowlist), each on its own hostname and port
- [x] Web tools for Search and News verified through the bridge (first real messages pending) — News bot 2026-09-07 (agent mode, sourced headline)
- [x] Operator uploaded the three Teams packages and set `/sethome` in each chat; Secretary re-issued with a fresh bot identity so the chat carries its name (Teams pins a 1:1 bot chat's name to the first contact) (web_search / web_extract / browser); News delivers its daily briefing by cron into its own chat

- [x] Decision (2026-09-05): one bot, Google only on explicit request. Alternatives were a second bot / gateway profile for private matters, or the WhatsApp bridge as the private channel. Several bots on one Bot Service identity are possible (Hermes multiplex profiles); each is a separate Teams app.
- [x] Implemented by the tool descriptions and the system prompt note in part 2/3 (no second bot)

## 6 · Later, not forgotten

- [x] Bridge research and hardening (2026-09-07): CLI agent mode (system prompt in the CLI's own slot, its tools off), `--disable-slash-commands`, `denied_actions` as the primary signal, permission-mode assertion, one retry on transient CLI failures, auto-update off, startup checks — docs/research/agy-cli.md
- [x] Secretary reads the operator's own mailboxes for receipts and invoices (2026-09-07): Exchange mailbox via Full Access delegation + Mail.Read.Shared, private Gmail via its own read-only sign-in; analysis on the bridge (Secretary moved off Kimi)
- [x] Sub-agents on another endpoint (2026-09-07): `BOT_<KEY>_DELEGATION_ENDPOINT` → `delegation` block; the Secretary hands mailbox analyses to `delegate_task` on the bridge — ADR 0022
- [x] Installer hardening (2026-09-07): servers' commands via runuser (a nested sudo under sudo-rs `use_pty` swallowed the paste-back and Ctrl-C); bots restart when their MCP servers' code or env changed (stamp per bot)
- [x] Bridge malformed-call failures (2026-09-07): native calls to caller functions taken as decisions, reminder on retry; `AGENT_TOOL_SEARCH=off` so MCP tools are inline; GitHub bot without terminal (toolset list) — docs/research/agy-cli.md
- [x] Installer speed (2026-09-07): `--only`/`--skip`, per-module timing, config keys compared before the agent's CLI is called, one restart per bot and run
- [x] Private/business split in OneDrive (2026-09-07): `Secretary/Business/` and `Secretary/Private/`, file names end with `_bus` / `_pri`, enforced by the drive tools, world decided at intake for every scan, photo, mail and task; `m365ctl migrate-worlds` for existing files; the same structure in the agent's Google Drive (`googlectl migrate-worlds`)
- [x] Text twin for every filed document (2026-09-07): `<name>.md` with the recognized text next to the scan, enforced by the upload tools; backfill via `m365ctl companions --apply` (PDF/Word) and the Secretary's eyes (photos)
- [x] Links in Teams (2026-09-07): named links keep their URL (adapter patch); SharePoint/OneDrive links opened through Graph's sharing endpoint (`m365_share_read`, `m365_share_download`, scope Files.Read.All)
- [ ] Reboot test of the four-bot host (units ordered after bridge/relay since 2026-09-07; never rebooted since the bots exist): reboot at a quiet hour, then the checklist in README part 5
- [ ] Receipts end to end: Teams question → delegate_task on the bridge → CSV in `Secretary/Receipts/<YYYY>/` — first real run pending
- [ ] Antigravity terms item 6 (third-party tools accessing the service): spawn-only wrapper is a grey zone Google has not answered; operator decision to record in an ADR

- [x] GitHub bot (2026-09-06): fourth bot on the bridge with the official GitHub MCP server 1.12.0, alias github@, Teams chat; live: lists the operator's repositories through the bridge
- [x] Decision (2026-09-06): the GitHub bot runs with the operator's admin token on purpose — full rights over every repository; safety comes from the role (merge, close, delete, force-push only on explicit confirmation), not from the token

- [ ] Every restart during a deploy sends "Gateway shutting down" to active sessions — by MAIL too, under the vendor's default subject "Hermes Agent" (six such mails on 2026-09-05). Upstream default; mitigate by deploying less often; ask upstream for a configurable subject / opt-out
- [x] Mail per bot on one mailbox (2026-09-06): aliases secretary@/search@/news@, Exchange rules by the run, each bot polls its folder (carried adapter patch for EMAIL_IMAP_FOLDER — upstream candidate). Gmail stays a tool, not a channel
- [ ] Replies as the alias (Exchange "send from alias") — today replies come from the primary address

- [x] Public pages (home, privacy, terms) under assistant.<zone> — module `site`; Google requires them to publish the OAuth app, Teams shows them
- [ ] Teams manifest: point websiteUrl / privacyUrl / termsOfUseUrl at the public pages (next bot release)

- [x] Secretary runs on an API model (Kimi K3 2026-09-05 → DeepSeek direct `deepseek-v4-flash-vision-exp` 2026-09-07, cheaper, reads images); Search, News, GitHub stay on the bridge — per-bot model configuration, `deepseek` a known hosted provider
- [x] Daily session reset at 04:00 for all bots (`AGENT_SESSION_RESET`)
- [x] Bridge stateless (ADR 0021); images handed to the CLI as files
- [x] Old bot identity retired: Entra app 2494e2b2… deleted 2026-09-06

- [ ] Old single-bot leftovers to retire: the old single-bot DNS record, the vendor unit file hermes-gateway.service (disabled), TUNNEL_HOSTNAME as a config key
- [ ] Removing a bot from BOTS should retire its Azure Bot, Entra app, DNS record, unit and profile (today: config only)
- [ ] Per-bot icons (`bot/assets/<key>.svg` → `bot/teams-app/<key>/`), today all three share one icon

- [ ] WhatsApp bridge channel (private mobile contact without a public bot)
- [ ] Dashboard over TLS (today: plain HTTP on the LAN, installer warns)
- [ ] Sporadic `IMAP fetch error: EOF` (self-healing; ~2 per 15 min) — root cause
- [x] Commit the repository (nothing is committed yet) and push to the private remote — public repository since 2026-09-06; only examples and structure files tracked, site configuration ignored
- [ ] Second VM: bootstrap → config → `az login` → `install.sh` → upload Teams package → `/sethome` → sign-ins (M365 device code, Google paste) — everything else automatic; run it and fix whatever is not

## 7 · Admin bot ("<prefix> Admin") — decided 2026-09-07

The operator's channel for the system itself: state questions, update
options, and change requests that Claude Code (Opus, the operator's
subscription) implements in the repository. Claude Code touches only the
repository; applying is opsctl's own step (`OPS_APPLY`: auto after a green
change — the operator's choice 2026-09-07 —, ask, or never): a request file
that a root-side path unit answers by running the installer, because the bots
run under NoNewPrivileges and the run restarts them, this one included.

- [x] Role `bot/roles/admin.md`; the bot acts only through `opsctl`
- [x] `bot/ops/opsctl`: status, report, check-updates, dry-run, change, modules-for; module `libs/66-ops.sh` installs it with `/etc/hermes-ops.conf`; the installer writes `last-run`
- [x] Configuration: `admin` in BOTS, Teams only, toolset with terminal (for opsctl) and no files; `OPS_ENABLED`, `OPS_CLAUDE_MODEL`, `OPS_CLAUDE_TIMEOUT`
- [ ] Full installer run (new Entra app, Azure bot, hostname, tunnel ingress, Teams package), upload the package, `/sethome`
- [ ] First change request end to end; check the Claude Code allowlist holds (no push, no install.sh)
- [ ] Daily 07:00 report set up by the bot; weekly `check-updates` reminder
- [x] `opsctl apply` / `apply-status`; `OPS_APPLY=auto` in the operator's configuration (decided 2026-09-07: "claude muss einen restart durchführen können")
- [ ] Later: the second VM maintained through the same bot

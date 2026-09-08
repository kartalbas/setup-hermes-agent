# Changelog — the bot

All notable changes to the code under `bot/` (the bridge, the MCP assistants,
the Teams app). The installer stamps the version into what it installs.

## Unreleased

## 0.4.0 — 2026-09-09

- Bridge: the caller's functions reach the model as REAL tools — an MCP server (`bot/agy-shim/tools_mcp.py`) the CLI spawns per conversation, registered with the CLI by the run together with its allow rule; a completed call to it is the decision, the framework still executes. Ends the "improperly formatted function call" retries that cost about half the subscription's turns since 2026-09-07 (ADR 0024, `AGY_SHIM_NATIVE_TOOLS`)
- Bridge: a decision the model abandoned and rewrote (two envelopes glued with a stray token) yields the rewrite; arguments encoded as a string — escaped or with unescaped quotes — are decoded (a Search answer reached the chat as raw JSON, 2026-09-08)

## 0.3.0 — 2026-09-08

- Tasks bot (`bot/roles/tasks.md`, MCP server `bot/mcp/tasks_assistant.py`, module `assistant`): tasks per tenant in Microsoft Planner — one plan in a Microsoft 365 group the run creates (`ASSISTANT_TASKS_*`; owner the operator, member the agent's account, optionally a Team), one bucket per tenant, every card assigned to the operator; `tasks_add` demands start and due date; `tasksctl status|tenants|due|digest`; the Secretary files deadlines as cards in its own bucket; scope `Tasks.ReadWrite` added and consented by the run
- Installer: `AGENT_CRON_DRIFT_GUARD` (default false) — reminders fire after a provider or model change instead of being skipped as "drift"

- Installer: `CHANNELS_COMMAND_ALLOWLIST` / `BOT_<KEY>_COMMAND_ALLOWLIST` record "Always allowed" approval categories in configuration (union with what the chat added)

- Teams: `/help` shows a short page per bot (name, one-line summary, five commands) from `bot/help.md.tpl`; the agent's developer list stays behind `/help all` (carried gateway patch); every role starts with a `> summary` line

- Admin bot: every change carries a read-only host snapshot (`opsctl snapshot`) and Claude Code may run read-only host commands (journals, status, the assistants' listings)

- Google assistant: the same drop folders in Drive (`google_drive_inbox`, `google_drive_file`, `googlectl inbox`); `inboxctl` lists both sides for the cron monitor
- Microsoft 365 assistant: drop folders `<root>/<World>/Inbox` (created by the run), `m365_drive_inbox`, `m365_drive_file` (move, rename, twin in one call), `m365ctl inbox` as a cron monitor; the Secretary files what the operator shares from the phone via OneDrive

- Housekeeping: per-bot `work/` directory as the terminal's cwd and TMPDIR, tmpfiles rules age out scratch and download folders, the bridge sweeps stale working directories at start, the persona forbids writing into home or /tmp

- Balance proxy (`bot/api-proxy/balance_proxy.py`, module `apiproxy`): the remaining API balance appended to every final answer of a bot on DeepSeek or Moonshot (`BOT_<KEY>_LLM_BALANCE`)

- Teams: carried adapter patch — a pasted URL rendered as a named link keeps its URL (`(link: …)`); M365 assistant: `m365_share_read` / `m365_share_download` open SharePoint and OneDrive links through Graph (`Files.Read.All`)
- Assistants: every document filed below the root gets a Markdown twin with its recognized text (`text_md`, refused without it for photos; PDFs extracted); `m365_drive_missing_text`, `m365_drive_download`, `m365ctl companions [--apply]`, `googlectl companions`
- Google assistant: the same worlds in Drive (`ASSISTANT_GOOGLE_ROOT_FOLDER` / `ASSISTANT_GOOGLE_WORLDS`, default the M365 values); `googlectl ensure-folder`, `migrate-worlds`, `move`
- Microsoft 365 assistant: private and business worlds below the root folder (`ASSISTANT_M365_WORLDS`), suffix per world enforced by the drive tools; `m365ctl migrate-worlds [--apply]` moves existing files

- Admin bot: `opsctl apply` writes a request and the root-side `hermes-ops-apply.path` runs the installer (the bots cannot escalate under NoNewPrivileges); `OPS_APPLY` auto/ask/never, `apply-status` shows the log
- Admin bot: `bot/roles/admin.md` and `opsctl` (module `ops`) — host state, update check, installer preview, and change requests that Claude Code turns into tested commits; the installer records its last run for it

- Bridge: a native call to a caller function (the CLI's `unknown tool` step) is taken as the decision; the retry after a malformed-call failure carries a plain-text reminder
- Installer: `AGENT_TOOL_SEARCH` (default off) puts MCP tools inline instead of behind the agent's meta-tools; per bot `BOT_<KEY>_TOOL_SEARCH`
- Installer: `BOT_<KEY>_TOOLSET` / `CHANNEL_TEAMS_TOOLSET` accept a list of the agent's toolsets — a bot without a terminal; the GitHub bot runs on `web memory session_search clarify cronjob todo`
- GitHub role: GitHub only through the `github_*` tools, never `gh`/`git` in the terminal
- Bridge: CLI agent mode (the system prompt in the CLI's own slot, its tools off), transient-failure retry, startup checks
- Roles: every bot translates; Search, News and GitHub directly (they run on the bridge), the Secretary — texts and documents — through `delegate_task` on the bridge
- Secretary role: every read of the operator's own mailboxes goes through `delegate_task`, so a bot on an API model reads them on the bridge (`BOT_<KEY>_DELEGATION_ENDPOINT`)
- Installer: bot units are ordered after the bridge and the mail relay; start timeout `SERVICE_START_TIMEOUT` (300 s) for a cold boot
- Installer: a persona change hands its restart to the channel pass — one restart per bot and run instead of two; what is still owed is restarted at the end
- Installer: `--only` / `--skip` / `--list-modules` to run part of it; per-module timing at the end; agent config keys are read before the agent's CLI is asked to set them (seconds per key per bot saved)
- Installer: the model block sets `base_url` explicitly (empty for a hosted provider) — the vendor's aggregator default in config.yaml otherwise hijacked a bot moved to a hosted provider
- Installer: bots restart when their MCP servers' code or env changed (stamp per bot); server commands via runuser, no nested sudo (the paste-back sign-in hung under sudo-rs use_pty)
- Assistants: read-only access to the operator's own mailboxes — Exchange via Full Access delegation and `Mail.Read.Shared` (`mailbox` parameter), Gmail via a second read-only sign-in per account (`account` parameter)

## 0.2.3 — 2026-09-06

- GitHub bot: fourth Teams app, official GitHub MCP server, mail alias

## 0.2.2 — 2026-09-06

- Teams manifest: `supportsFiles` so the chat offers the attach button (letters, invoices, photos)

## 0.2.1 — 2026-09-06

- Secretary on a fresh bot identity so Teams names the chat after the app

## 0.2.0 — 2026-09-05

- three bots (Secretary, Search, News), each its own Teams app, profile and service
- version bump for all three packages at once

## 0.1.1 — 2026-09-05

- Teams app id derived from the bot's client id (no collision with earlier uploads)
- one package per bot (secretary, search, news) with the bot's name and hostname
- bridge: reminder once when the model reaches for a denied built-in tool
- Microsoft 365 assistant MCP server (mail, calendar, meetings with roles, OneDrive)

## 0.1.0 — 2026-09-05

- agy bridge with tool calling through the tool contract
- Teams app manifest and icons generated from configuration

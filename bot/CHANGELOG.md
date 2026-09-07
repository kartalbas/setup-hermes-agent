# Changelog — the bot

All notable changes to the code under `bot/` (the bridge, the MCP assistants,
the Teams app). The installer stamps the version into what it installs.

## Unreleased

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

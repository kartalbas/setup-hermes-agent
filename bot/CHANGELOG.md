# Changelog — the bot

All notable changes to the code under `bot/` (the bridge, the MCP assistants,
the Teams app). The installer stamps the version into what it installs.

## Unreleased

- Bridge: CLI agent mode (the system prompt in the CLI's own slot, its tools off), transient-failure retry, startup checks
- Roles: Search translates; the Secretary translates too, but through `delegate_task` on the subscription bridge
- Secretary role: every read of the operator's own mailboxes goes through `delegate_task`, so a bot on an API model reads them on the bridge (`BOT_<KEY>_DELEGATION_ENDPOINT`)
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

# 0020 — One bot per role, declared as a list

Date: 2026-09-05 · Status: accepted

## Context

The operator wants separate Teams chats for separate jobs — a secretary, a
researcher, a news desk — without switching roles inside one conversation, and
nothing user-visible named after the vendor. In Teams, a bot in a team channel
answers only when @-mentioned, so channels of one team are not the answer; a
1:1 chat per bot is. The agent (Hermes) supports profiles: complete homes with
their own persona, memory, tools and channel credentials, sharing one code
install.

## Decision

`BOTS` is a list of keys. Every bot has derived defaults for everything else
(`bot_field`): display name `<BOT_PREFIX> <Name>`, hostname `<key>.<zone>`,
webhook port `BOT_PORT_BASE + index`, unit `<BOT_SERVICE_PREFIX>-<key>`, Azure
Bot of the same name, Entra app named like the display name, persona from
`bot/roles/<key>.md`. A bot is one word in `BOTS` plus that role file.

Per bot the run: creates the Entra app and writes its client id and secret
into the secrets file (which stays the single source), declares the Azure Bot
in Bicep and retires a bot that holds the same app id under an old name,
builds the Teams package, creates the profile as a clone of the default with
its channels switched off, writes SOUL.md, writes the systemd unit, configures
the profile's channels and MCP servers, and restarts only what changed. The
tunnel publishes one hostname per bot to its own loopback port. The dashboard
shows the bot declared with `DASHBOARD=true`. The default profile runs no
gateway once bots exist.

Shared between bots: the agent code, the bridge, the mail relay and the
assistant's token and virtualenv. One bot carries the mailbox (`email` in its
channels); one carries the dashboard.

## Consequences

- Each bot is its own Teams app to upload once, and `/sethome` once per chat.
- Admin consent on the shared mail app must cover every consumer (relay and
  assistant) — see the README's troubleshooting entry; the run declares both
  and verifies the grant after consenting.
- Adding, renaming or removing a bot is a configuration change; the run does
  the rest. Removing a bot does not yet delete its Azure resources (part of
  `docs/plan.md`).

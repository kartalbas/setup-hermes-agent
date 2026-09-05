# 0019 — Own MCP servers for the assistant, one account per world

Date: 2026-09-05 · Status: accepted

## Context

The operator wants a personal assistant, not a chat window: mail, calendar,
Teams meetings with roles, files — in Microsoft 365 by default and in a private
Google account on request, and later letters read and turned into reminders.
The agent (Hermes) gains capabilities through MCP servers.

Two ready-made servers were examined. The Microsoft 365 one (300+ tools,
npm) cannot set meeting roles (no `PATCH /onlineMeetings`) and uses delegated
device-code auth with its own encrypted token cache; the Google ones assume a
browser on the same machine. Neither gives control over tool descriptions,
which matter here because tool calls travel through the agy bridge's tool
contract (ADR 0017).

## Decision

Two small MCP servers of our own under `bot/mcp/`, Python standard library plus
`pypdf` and `python-docx`, installed by the `assistant` module into a venv and
registered under `mcp_servers`. One account per world: the Microsoft 365 server
acts as the agent's mailbox account; the Google server as the agent's Gmail
account. Delegated permissions only, a device-code (M365) or paste-back
installed-app (Google) sign-in once, refresh tokens in 0600 files, and an
identity check that refuses a token for any other account.

The routing rule — business is the default and Microsoft 365; "privat" means
Google — is stated in the servers' own instructions and tool descriptions, so
the model routes by itself and no second bot is needed for it.

Scopes are declared and admin-consented by the installer (`az`) on the existing
public-client app, so the sign-in never stops at a consent screen.

## Consequences

- Meeting roles work (`PATCH /me/onlineMeetings/{id}` after creation).
- Every tool is a few lines we can read, test against a fake Graph, and shape
  for the bridge. The test suite runs the servers over stdio.
- The operator signs in twice more (M365, Google), once each. Everything else is
  the run.
- Photographs of letters need image-to-text; that is not in this release and is
  tracked in docs/plan.md part 4.

# 0022 — The operator's own mailboxes: read-only, analysed by sub-agents on the subscription

Date: 2026-09-07 · Status: accepted

## Context

The Secretary is meant to process what arrives in the operator's *own*
mailboxes — receipts, incoming invoices, letters — not only what reaches the
agent's mailbox. Two constraints met here:

- The operator's mail must not be sent to a paid API. The bots' default model
  is the subscription behind the bridge; the Secretary, however, runs on an API
  model because it needs exact tool calling and images for its other work.
- The agent must never be able to *act* in the operator's mailboxes. Reading is
  wanted; sending, moving, marking or deleting there is not.

The agent runs one model per profile. A per-task model switch does not exist,
but the agent's `delegate_task` tool builds sub-agents from a `delegation`
block that can name another endpoint, and sub-agents inherit the parent's MCP
tools.

## Decision

1. **Access is configured as lists of other people's mailboxes, read-only.**
   `ASSISTANT_M365_READ_MAILBOXES` (Exchange, same tenant) and
   `ASSISTANT_GOOGLE_READ_ACCOUNTS` (other Google accounts). The read tools take
   the mailbox as a parameter; the write tools have no such parameter. Both
   servers refuse an unlisted mailbox before asking the API.
2. **Exchange: Graph `/users/<address>` with `Mail.Read.Shared`.** The scope is
   added and consented by the run when the list is non-empty. The mailbox
   delegation itself is an Exchange setting Graph does not expose; the run
   checks it (`m365ctl check-mailbox`) and names the click path when it is
   missing. Full Access is the only delegation the admin center offers, so the
   read-only limit is the server's, not Exchange's.
3. **Google: one token per account, obtained by signing in as that account with
   `gmail.readonly` only.** The agent's own token is never used for another
   account; the read account's token can do nothing but read.
4. **The analysis runs on the subscription through delegation.**
   `BOT_<KEY>_DELEGATION_ENDPOINT=<n>` renders the profile's `delegation` block
   from a global `LLM_ENDPOINT_<n>`; the Secretary's role says to hand these
   analyses to `delegate_task`. The bot on the API sees the extract, not the
   mail. Two shapes are allowed — a keyless custom endpoint (the bridge) or a
   hosted provider by name — and a custom endpoint with a key is refused,
   because the block would have to carry the key in `config.yaml`.

## Consequences

- A per-mailbox grant is visible in configuration and in the tools'
  descriptions; nothing is reachable that is not listed.
- Reading needs one manual step per world: the Exchange delegation by a tenant
  admin, the Google sign-in as the account. Both are done once.
- Delegated analyses take longer (a fresh sub-agent per task) and cost bridge
  quota; the Secretary's own turns stay cheap.
- The extract still passes through the API model. What the operator wants kept
  off the API is the mail itself, and that holds.

## Alternatives considered

- **Move the Secretary to the bridge.** Simplest, but gives up the API model
  where it earns its place (tool precision, images) — and the operator had just
  chosen a cheaper API model for exactly that.
- **A separate "receipts" bot on the bridge.** One more Teams chat for a task
  the operator sees as the Secretary's; rejected for that reason.
- **The agent's mailbox as a delegate in Outlook only.** Same grant, but no way
  to hold the server to read-only; the tool surface is where the limit lives.

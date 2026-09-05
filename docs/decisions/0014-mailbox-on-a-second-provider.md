# 0014 — The agent's mailbox lives with a second provider

**Status:** accepted

## Context

The intent was one identity for everything: mailbox, calendar, chat, and
free/busy in a single tenant. That is still the better architecture, and it is
not available.

The mail adapter authenticates with a password. The preferred provider disabled
basic authentication for IMAP across all tenants and states that neither the
customer nor its own support can re-enable it. An app password does not help:
app passwords *are* basic authentication.

The remaining routes were a local relay speaking OAuth outward and plain IMAP
inward, or a mailbox somewhere that still accepts an app password. A working
app password for a second provider already existed.

## Decision

Put the agent's mailbox with the provider whose app password works. Keep the
first provider for chat, and for calendar identity.

## Consequences

- The mail channel works today, with no additional service to run or maintain.
- **Free/busy is lost.** The agent cannot see when the user is already busy, so
  its proposals will occasionally land on an occupied slot. The user still
  accepts or declines, so nothing is scheduled wrongly — the cost is a worse
  suggestion, not a wrong calendar.
- Calendar invitations still work: an `.ics` invitation is a standard and
  crosses providers intact, so accepting one in the user's own client writes it
  to the user's own calendar.
- Two accounts to keep alive instead of one, and the agent's correspondence
  comes from an address that does not match its chat identity.
- A local OAuth relay remains the way to recover free/busy later: it would speak
  OAuth outward and plain IMAP inward on loopback, which the adapter documents
  and supports. It is not built; whether to build it should be driven by how
  often the scheduling suggestions actually miss.

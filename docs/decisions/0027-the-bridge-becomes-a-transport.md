# 0027 — The bridge becomes a transport, and context management moves out of it

Date: 2026-09-12 · Status: **proposed** · Supersedes part of ADR 0021, refines ADR 0024

## Context

The bridge (`bot/agy-shim/agy_shim.py`) exists for one reason: the agent
framework speaks OpenAI chat completions over HTTP, the subscription CLI is a
subprocess speaking NDJSON on stdio, and the operator's rule is *subscription,
never API*. Remove that rule and the bridge disappears the same day, replaced
by a vendor API key. Keep it, and something has to translate.

That part is not in question. What is in question is everything else the file
does. Measured on 2026-09-12, by function body:

| Concern | Lines |
|---|---|
| Text tool protocol and its rescue parser (`parse_decision` alone: 104) | 221 |
| Reshaping the message: framing, trimming, per-entry cap | 105 |
| Warm spare processes | 52 |
| **Sum** | **378 of 1828 (20%)** |

With constants, call sites and the reminder texts, roughly a quarter of the
file. Every line of it exists for the same reason: to simulate a session on
top of a stateless print mode.

The operator's objection, stated plainly: the bridge should be a bridge, not
something that modifies the message on the way in and on the way out. Anything
that genuinely needs to shape content should do it somewhere else.

Two findings make that objection actionable.

**The cutting is worse than it was ever described.** Two mechanisms, not one:

```
ENTRY_CAP = 6000        every single entry truncated at 6000 characters, always
budget    = 120000      whole older entries dropped once the total exceeds it
```

The per-entry cap was written for scraped HTML and applies to everything: a
long mail, a fetched page, the operator's own long message. About a page and a
half, then the rest is replaced by a count. `--history-budget 0` disables
both, because `trim_history` returns before it reaches the cap.

**The text tool protocol is already dormant.** `--native-tools auto` resolves
to `tools_server_configured()`, which is true in this installation. The 221
lines of text protocol, including the rescue parser written for envelopes the
model truncated mid-object, are a fallback that does not run here.

### The structural finding

The bridge cannot both stop modifying messages and stay stateless.

OpenAI chat completions sends a **list** of role-tagged messages, complete, on
every request. The CLI's stream-json mode takes **one** message per line into
a **running** conversation. A bridge that starts a fresh process per request
must flatten the list into a single message. That flattening *is* the
modification being objected to. It is not a design mistake that can be fixed
in place; it is what the two shapes force on anyone who refuses to hold state.

Hold a session per conversation and the mapping is clean: the system prompt
goes in once as an agent definition, which is the CLI's own supported
mechanism for a persona; each new message goes in verbatim as one line; tool
results travel the native MCP channel. Nothing is flattened, framed, trimmed
or capped.

So the operator's architectural principle and the operator's older request for
a standing instance are the same request, arrived at from two directions.

### Where context management belongs instead

Not in the bridge, which sees an anonymous list and can only cut by character
count. Two places know more:

- **The agent framework** owns the conversation, the user and the topic, and
  already has `session_reset` per bot.
- **The CLI** compacts its own context at a token threshold it can measure and
  the bridge cannot.

## The plan

Three moves. The first two are pure removal and need no backend change. The
third is a fork that one experiment decides.

### Move 1 — stop cutting content

Set `--history-budget 0`, then delete `trim_history`, `ENTRY_CAP`,
`DEFAULT_HISTORY_BUDGET`, the trimming inside `transcript_block`, and the
config keys that carry them. What bounds the prompt afterwards: the CLI's own
compaction and `session_reset` on the framework side.

### Move 2 — delete the text tool protocol

Set `--native-tools on` instead of `auto`, then delete `parse_decision`, its
payload helper, and the text branch of `tool_contract`. Roughly 140 lines; the
native branches of `tool_contract`, `mcp_call_decision` and the tools-file
writers stay, because they serve the channel ADR 0024 established.

The bridge then *requires* the MCP tools server. That is a real trade and is
listed under costs.

### Move 3 — a session instead of a process per request

Either back end removes `transcript_message`, `stateless_message`,
`pending_request`, the framing helpers and the warm spares: about 100 further
lines.

**3a — the `--stateful` mode already in the tree.** Measured 2026-09-10: 2.5×
the input tokens of the stateless path, 44% faster, identity held in agent
mode. Exists, needs no new dependency and no new login. But the CLI
accumulates the conversation in its own context and re-sends it upstream,
which is *why* it costs 2.5×, and that is not a knob we hold. The conversation
lives inside a process, so a restart loses it.

**3b — `agy_acp_server`, the official ACP server.** Purpose-built: `session/new`
takes an `mcpServers` array, `session/prompt` carries a turn, the session is
persistent by construction. Official Google software, versions 1.0.0 and
1.1.1, distributed through Zed's ACP Registry with a runtime published for
linux-x64 among others, authenticated with Google's own OAuth. It removes the
most code because the protocol does natively what this repository hand-rolled.

3b is **not decidable today**. One question blocks it: can the server be
fetched, started and authenticated headless, outside the registry UI of an
editor? Until that is answered, 3b is a hypothesis.

## What the plan buys

1. **Nothing is truncated any more.** A long mail arrives whole. This is the
   operator's actual complaint, and Move 1 alone answers it.
2. **About 270 lines go, and they are the lines with the highest defect
   density.** The rescue parser exists because the protocol broke; the framing
   exists because questions drowned in tool output. Removing the cause removes
   the class.
3. **A whole class of bug becomes impossible.** "The bot answered an earlier
   question" cannot be caused by framing when there is no framing.
4. **Context decisions move to the two components that have the information.**
5. **What remains is small enough to reason about**, and small enough to
   replace later without a rewrite.

## What the plan costs

1. **Tokens go up, and the direction is the opposite of this project's
   origin.** Untrimmed plus stateful means the full conversation on every
   turn. Stateful alone measured 2.5×; untrimmed adds to that. The current
   measurement makes it affordable (weekly quota at 99–100% remaining, about
   1% consumed per week), but affordability is not the same as free, and it
   depends on a number that could change with usage.
2. **A control is handed over.** Trimming was blunt, but it was ours. After
   this, bounding context depends on the CLI's compaction: closed source, and
   free to change on any update.
3. **Removing the text fallback removes a fallback.** If the MCP tools server
   fails to start, the bots have no tools at all rather than degraded ones.
   This must fail loudly at install time, not quietly at the first turn.
4. **A session is stateful on a host that restarts.** Every deploy restarts
   the bots today; with sessions, every deploy drops every conversation. For
   3b this is worse than theoretical: a session unrecoverable after a process
   restart is an open bug in the vendor's own tracker.
5. **Move 3 may not be reachable.** If the ACP server cannot be authenticated
   headless, what is left is 3a, whose prize is smaller for the same
   disruption.
6. **Identity risk returns.** ADR 0021 retired the stateful pool partly for
   drift. Agent mode closed that in a ten-turn measurement; a session that
   lives for days is a longer exposure than the test that cleared it.
7. **This is elective surgery on the component every bot depends on.** Six
   bots answer today.

## The alternative this plan is measured against

Do Move 1 and stop. One configuration value, no code deleted, no risk, and the
operator's stated grievance is gone: nothing is cut at 6000 characters any
more. Everything after that is architecture, not a fix.

Naming this honestly matters, because Moves 2 and 3 are worth doing for the
shape of the system, not because anything is currently broken.

## Decision needed

1. Move 1: yes or no. Independent of everything else.
2. Move 2: yes or no. Independent of Move 3.
3. Move 3: run the headless experiment on the ACP server first, or settle for
   3a, or leave the back end alone.

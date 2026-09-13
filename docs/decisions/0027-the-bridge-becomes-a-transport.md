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

**3c — the CLI's own local server.** The operator's question: rather than
wrapping the binary, talk to the server the binary itself runs. Two pieces of
evidence say such a thing exists. The CLI carries a `remote-control` subcommand
that starts a background daemon registered as `antigravity-cli-daemon.service`,
and at least one community ACP adapter describes itself as driving "a warm
language server over its local Connect API". On this host the daemon does not
start, for a mundane reason: no user D-Bus session, because nothing here runs
in a desktop session.

3c is the closest thing to "stop wrapping" that exists, and it is warm by
construction, so it would remove the spawn cost without any of the framing.
Its defect is one the other two do not share: this is an **internal**
interface. No documented protocol, no compatibility promise, and a vendor free
to change it on any update. It is not the kind of dependency the 9router
discussion ruled out, because it is our own installation talking to its own
local server with its own login, and nothing is impersonated. It is simply
fragile in a way a published protocol is not, and the failure would be silent.

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

1. **Tokens go up.** Untrimmed plus stateful means the full conversation on
   every turn. Stateful alone measured 2.5×; untrimmed adds to that.

   **Corrected 2026-09-13, on the operator's premise and on the evidence.**
   The yardstick of this project is answer quality; tokens are a constraint to
   respect, never a reason to give quality away. Measured against that
   yardstick, "more context reaches the model" is the goal, not the price, and
   this line is only a cost to the extent that the quota is finite. It is not
   currently near finite: 99–100% of the weekly limit remains, about 1%
   consumed per week.

   The 2.5× figure also deserves its caveat stated where it is used, not only
   where it was recorded. It was measured with `cached` at **zero on every
   single request in both modes** — two cold instances, prefixes nobody had
   sent before. Production is nothing like that. Over 917 turns in seven days
   on this host:

   | | |
   |---|---|
   | turns with a cache hit | 623 of 917 (**67%**) |
   | on a hit: cache read / input | 78,738 / 65,628 |
   | without a hit: input | 24,962 |

   Note that `cache_read_tokens` is a **separate counter, not a subset of
   `input_tokens`** — 197 turns report more cached than input. The A/B script
   computed `marginal = input − cached` on the opposite assumption, so that
   column of the 2026-09-10 table does not mean what it says.

   And the direction of the cache favours the option this ADR is weighing. The
   earlier three-turn measurement recorded in the bridge header: a fresh
   process holds its cache flat at 8,131 while paying ~14k new tokens a turn; a
   living process reads 8,124 then 16,242, growing with the conversation, while
   paying ~5.9k. Cold, statefulness looks 2.5× worse. Warm, it may look better.
   **Nobody has measured warm**, and no move in this plan should be justified
   by the cold number in either direction.
2. **A control is handed over.** Trimming was blunt, but it was ours. After
   this, bounding context depends on the CLI's compaction: closed source, and
   free to change on any update.
3. **Removing the text fallback removes a fallback.** If the MCP tools server
   fails to start, the bots have no tools at all rather than degraded ones.
   This must fail loudly at install time, not quietly at the first turn.
4. **A session is stateful on a host that restarts.** Every deploy restarts
   the bots today; with sessions, every deploy drops every conversation. For
   3b this is worse than theoretical: a session unrecoverable after a process
   restart is an open bug in the vendor's own tracker — though the server does
   advertise `loadSession`, `session/list` and `session/resume` (measured
   2026-09-13), so the protocol has the vocabulary even where the
   implementation stumbles.
5. ~~**Move 3 may not be reachable.**~~ **Answered 2026-09-13, and the answer
   is that it is reachable.** The ACP server downloads from `dl.google.com`
   through the registry's machine-readable index with no editor involved,
   starts headless once given `--uid=` (without it it aborts looking for a
   group named `nobody`, which Ubuntu does not have), and answers `initialize`
   with ACP v1. It does not inherit the CLI's login, and `session/new` without
   configuration returns "Authentication required"; with
   `auth.type: oauth-personal` it emits an ordinary Google OAuth URL with a
   **loopback redirect**, which is the one interactive step and the one thing a
   host with no inbound route cannot complete unaided. An SSH port-forward of
   that port closes it. Full record in `docs/research/agy-cli.md`.

   What remains as a cost rather than a blocker: **2.6 GB on disk** against the
   CLI's 213 MB, and a second binary with its own update path and its own
   login.
6. **Identity risk returns.** ADR 0021 retired the stateful pool partly for
   drift. The warm A/B of 2026-09-13 is now a **second independent run in which
   identity held in both modes** at all three probes, so this is the weakest
   remaining objection.
7. **This is elective surgery on the component every bot depends on.** Six
   bots answer today.

### How the operator prices these

Stated 2026-09-13: **outages are acceptable.** That is not a detail; it
discounts items 3, 4 and 7 almost to nothing, since each of them is an
availability cost rather than a correctness one. What survives at full weight
is item 2, handing context bounding to a closed-source compaction we do not
control, and the residue of item 5, which is size and a second thing to keep
logged in.

The plan should therefore be read with availability risk priced low and
architecture priced high, which is the opposite of how the cost list above was
originally weighted.

## The alternative this plan is measured against

Do Move 1 and stop. One configuration value, no code deleted, no risk, and the
operator's stated grievance is gone: nothing is cut at 6000 characters any
more. Everything after that is architecture, not a fix.

Naming this honestly matters, because Moves 2 and 3 are worth doing for the
shape of the system, not because anything is currently broken. It is however a
weaker alternative than it was when first written: 3b has since been shown
reachable, and the operator has priced the availability risk that made "stop
here" attractive at close to zero.

## What cannot be decided by experiment, and why

Two synthetic A/B runs have now failed to reproduce the production prompt
cache: zero cache reads in both modes on both occasions, against 67% of turns
hitting in production over the same week. The difference is repetition over
days, which no priming turn reproduces. So the cost comparison between a
stateless and a stateful back end **cannot be settled in a laboratory**, and
neither the `+155%` of 2026-09-10 nor the `+587%` of 2026-09-13 should be cited
as if it could.

The measurement that would settle it is one production bot on `--stateful` for
a week, compared against its own history on its own traffic. With outages
acceptable, that experiment is cheap to run and is the obvious next step before
Move 3 is chosen.

## Decision needed

1. Move 1: yes or no. Independent of everything else.
2. Move 2: yes or no. Independent of Move 3.
3. Move 3: run the headless experiment on the ACP server first, or settle for
   3a, or leave the back end alone.

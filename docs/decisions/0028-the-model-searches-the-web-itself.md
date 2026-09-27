# 0028 — On the bridge, the model searches the web itself

Date: 2026-09-28 · Status: accepted · Refines 0024 (the caller's tools as native MCP tools) and 0026 (a role's tools follow its text)

## Context

Since ADR 0024 the bridge switches every tool of the CLI off (`tools: []` in the
agent definition, `commandExecutionPolicy: off`) and offers the caller's
functions in their place. The reason was sound and still is: the CLI's own
tools act — a terminal, file writes — and an action has to run through the
agent framework and its approval rules, not around them. Web search went with
them, as a side effect rather than a decision.

It came back as the agent's own `web_search`, on its default backend: keyless
Firecrawl. Measured on the news bot, 2026-09-21..27: 38 searches answered, 18
refused with `403 Forbidden` — a third. The operator's question was the obvious
one: why search through someone else's service when the subscription's model
can search itself?

Probes, 2026-09-28, the CLI driven exactly as the bridge drives it (stream-json,
`--agent`, a fresh workspace per run), production untouched:

| Probe | Result |
|---|---|
| `tools: [search_web, read_url_content]` in the agent definition | the agent starts (MCP tool names there kill it, 2026-09-09; built-in names do not). `search_web` runs headless with **no** allow rule: three searches, 25.6 s, a correct and current answer (the SNB decision of 24.09.2026, with date and source) |
| `read_url_content` | auto-denied, empty turn; stderr names the rule: `read_url(<target>)` in the CLI's `settings.json` |
| "run `ls -la /`" with the web pair enabled | refused by the model itself: no terminal tool exists |
| `tools: [search_web]` + a caller function in the tools server | `call_mcp_tool` still works; search and caller call in ONE turn work too, and the search result lands in the call's arguments |
| over ACP | every built-in asks `session/request_permission`: title `Run search_web?` (kind `search`), `Run read_url_content?` (kind `fetch`); the agent definition is ignored there |

The news bot's scheduled briefing showed a second problem on the way: cron had
no toolset of its own configured, so it ran on the agent's full default — a
terminal — and fetched RSS feeds with `curl`, one of them frozen since January
2025. Mail had the same gap.

## Decision

1. **The CLI's read-only web tools are configuration**: `AGY_SHIM_BUILTIN_TOOLS`,
   default `search_web`. The bridge lists exactly those in the agent definition
   (`tools: [search_web]`) and refuses any name outside the read-only pair
   `search_web`, `read_url_content`; `commandExecutionPolicy: off` stays.
   Nothing that acts is ever switched back on.
2. **The texts the model reads say the same thing**: the tool contract, the
   project instructions, both reminders. A contract that still said "never try
   the web yourself — disabled" would keep the model from the search it was given.
3. **`read_url_content` stays off by default.** It reads a page from THIS host,
   so it reaches whatever the host reaches — loopback services, the LAN — and a
   prompt injection in a page or a mail could point it there. Whether it does
   was not tested (the probe needed `--dangerously-skip-permissions` and was not
   run). Enabled, the run writes the `read_url(*)` rule the CLI needs.
4. **On the agent's side, only `web_search` goes.** A bot whose every endpoint is
   the bridge gets the one-tool toolset `search` in `agent.disabled_toolsets`,
   which the agent subtracts after every platform list, cron's included.
   `web_extract` stays: the news and search bots read pages with it (28 calls,
   no failure) and never used the browser tools. Removing all of `web` was
   considered and rejected for exactly that loss. A bot on an API model (the
   Secretary) keeps `web_search`; so does a chain with a fallback on an API.
5. **Over ACP the permission reply is the switch**: the client allows a built-in
   whose title is exactly `Run <name>?` for a configured name, and refuses the
   rest as before. The server runs it inside the turn; it is not a decision.
6. **The bridge logs each lookup** (`built-in search_web done: <query>`): the
   agent never sees the searches, only the answer with its sources.
7. **Every way into a bot gets the bot's list** — Teams, mail, cron — and each
   bot its own list (the per-bot pass had been handing a bot the previous
   bot's).

## Consequences

- Search runs on the subscription with Google's index, inside one turn. Through
  the agent, each search was a round trip that re-sent the whole transcript.
- The agent's transcript holds the answer and its sources, not the search
  results; a follow-up question searches again. The journal holds the queries.
- Searches spend subscription quota (22.5k input tokens for a three-search
  question in the probe).
- The search tool is the vendor's and closed source; a CLI update can change it.
  `AGY_SHIM_BUILTIN_TOOLS=""` returns to the agent's `web_search` with one run.
- Every bot on the bridge can search, not only News and Search — the agent
  definition is the bridge's, not the bot's. Search only reads.
- Mail and cron lost the terminal and file tools on bots whose roles never
  allowed them (News, Search, GitHub, Tasks); the Admin bot's list names its
  terminal and keeps it.

## Alternatives considered

- **A free search backend for the agent (ddgs, brave-free, SearXNG).** Works
  (ddgs answered in 1.0 s from this host), but it is a third-party service with
  its own limits, for a model that can search itself on the subscription.
- **The bridge hides the agent's `web_search` from the tool list.** Rejected by
  the operator's rule that the bridge carries messages and does not edit them;
  the agent's own `disabled_toolsets` does the same outside it.
- **`read_url_content` on by default.** Deferred until the loopback reach is
  tested; the agent's `web_extract` covers page reads meanwhile.

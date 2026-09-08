# 0024 — The caller's tools reach the model as real tools, not as a text protocol

Date: 2026-09-09 · Status: accepted (refines ADR 0017, which established that the model decides and the framework executes)

## Context

The bridge uses a coding-agent CLI as the model behind the agent framework
(ADR 0017). The framework's functions had to reach the model somehow, and the
CLI has no way to declare a caller's functions — so they were written into the
prompt as a TOOL PROTOCOL: "answer with one JSON object naming the function".

The model did not keep to it. Gemini emits *native* function calls, and with
no function declared every native call is rejected by the API as an
"improperly formatted function call"; the CLI retries three times internally
and fails the turn. Measured on this host:

| day | turns served | turns lost to malformed calls |
|---|---|---|
| 2026-09-06 (before agent mode) | 107 | 3 |
| 2026-09-07 | 63 | 96 |
| 2026-09-08 | 43 | 44 |

The bridge caught what it could — a parseable native call taken as the
decision, one retry on a fresh process with a reminder — but roughly half the
subscription's turns since 2026-09-07 were spent on repetition, and the rest
surfaced to the operator as "the model provider failed after retries". The
same pressure had already pushed the Secretary onto a paid API.

Experiment E8 (docs/research/agy-cli.md, 2026-09-09) answered the question
this rests on: the CLI **does** load MCP servers in headless stream-json mode,
also under `--agent … tools: []`, and the model then calls those tools
natively and correctly — nine turns, zero malformed calls, and it chained two
calls inside one turn on its own.

## Decision

**The caller's functions are offered to the CLI as a real MCP server, and a
call to that server is the decision.**

1. `bot/agy-shim/tools_mcp.py` is that server. It reads `tools.json` from its
   **working directory** — the per-conversation directory the bridge creates
   and the CLI is spawned in — so one global server entry serves every bot
   with that bot's own functions.
2. The server does **not** execute anything. It validates the arguments
   against the schema, records the call, and answers with a handoff note. The
   agent framework executes, under its own approval rules; ADR 0017 stands
   unchanged in substance.
3. Validation is load-bearing, not decoration: the model's first attempt at a
   multi-argument tool often arrives with empty arguments, and the error
   ("missing required 'tenant'") makes it correct itself inside the same turn
   for about a thousand tokens. So an incomplete call is never taken as a
   decision — only a completed one is.
4. The installer registers the server in the CLI's own `mcp_config.json` and
   adds `permissions.allow: ["mcp(tools/*)"]` to its settings, both by
   **merging** — the CLI writes those files too. Without the allow rule
   headless mode auto-denies every call; the bridge still salvages the
   arguments so the turn is not lost, and says what is missing.
5. The text protocol stays as the fallback for a CLI whose configuration does
   not name the server (`--native-tools auto`, the default, decides per start).

## Consequences

- The malformed-call retries disappear, and with them roughly half the
  quota spent since 2026-09-07.
- The prompt loses the schemas: the contract shrinks from every parameter of
  every function to one line per function. What the model needs to call
  correctly it now gets as a real tool declaration.
- A process's toolset is fixed for its life — the CLI asks the server for its
  list once, at start. Pre-warmed spares can therefore only serve requests
  without tools; a request with tools spawns its own process. That is the
  price of the channel, and it is the same price agent mode already pays.
- One more moving part in the CLI's own configuration, which the CLI also
  writes. Merged, never rendered — the same rule as ADR 0010 for the agent's
  config.yaml.
- The bridge now depends on a file layout of the CLI's (`~/.gemini/…`). It is
  read for detection only, and a wrong guess costs the text protocol, not the
  turn.

## Alternatives considered

- **Keep the text protocol and harden the parser.** Done as far as it goes
  (2026-09-08: an abandoned envelope and its rewrite, string-encoded
  arguments). It rescues turns after the fact; it cannot stop the model from
  reaching for a channel that does not exist.
- **ACP through a community adapter**, as Traycer does. Same idea one layer
  further out, with a third-party adapter around the same CLI and a session
  model this bridge deliberately gave up (ADR 0021). No gain over talking to
  the CLI directly.
- **Let the CLI execute its own tools.** Less work, and it puts every command
  outside the framework's approval rules. Refused in ADR 0017 and refused
  again here.

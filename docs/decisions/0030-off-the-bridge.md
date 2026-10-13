# 0030 — Off the bridge: a free API tier, and a bridge switched off is gone

Date: 2026-10-13 · Status: accepted · Leaves 0024/0027/0028 in force for an installation that keeps the bridge; changes what switching it off means

## Context

The bridge (0012, 0024, 0027) put a subscription CLI behind an OpenAI-shaped
endpoint so that the bots could run on a subscription instead of an API. Two
things ended that for this installation's operator:

- **The CLI's quota.** It answered "Individual quota reached" and named a
  reset almost a day away; every bot on the bridge was down until then. A
  subscription's model is now usable on the web, not through the CLI.
- **The terms were always grey** (the CLI's own terms on automated use). An
  outage the operator accepts; driving the web app instead — a browser
  automated against a consumer product, or its sign-in reused — is the same
  question asked louder, and was ruled out.

What the bots need from a model is ordinary: chat completions with tool calls,
images, a long context. The agent speaks to Google AI Studio natively
(provider `gemini`, aliases `google`, `google-gemini`, `google-ai-studio`), and
AI Studio has a free tier: a key from a project without billing and limits
per minute and per day. Outside the EEA, Switzerland and the UK the provider
may also use what is sent to improve its products, and people may read it;
inside them the paid tier's data terms apply to the free tier as well — no use
for product improvement, logs kept for a limited time against abuse. The
operator chose the free tier: free first, outages accepted.

Switching the bridge off, however, did not take it away. `agyshim_apply` only
skipped when `AGY_SHIM_ENABLED=false`; the unit kept running, the token and the
1.9 GB ACP server stayed, and the CLI — binary, data, sign-in — stayed in the
account's home. Removal existed only in a function nothing called. And the
agent's own web search, which the bridge had replaced with the model's (0028),
came back as a keyless rotation that had refused a third of the news bot's
searches.

## Decision

1. **The bots run on a hosted provider by name.** For Google's models that is
   the agent's `gemini` provider with `GEMINI_API_KEY` from the secrets file;
   the run maps the provider to the variable the agent reads. A bot that needs
   a paid API keeps its per-bot settings (`BOT_<KEY>_LLM_*`, the balance
   footer); sub-agents follow `BOT_<KEY>_DELEGATION_ENDPOINT` to whichever
   endpoint it names. When the free tier's quota is spent, a bot answers with
   the provider's refusal until it resets — no paid fallback is configured
   behind it, by choice.
2. **Switched off means absent.** With `AGY_SHIM_ENABLED=false` the run removes
   what the bridge put on the host: the unit, its scripts, its token, the ACP
   server and the harness beside it, the version it stamps. Not the balance
   proxy, which shares the directory and belongs to its own module. A run with
   nothing left to remove says so and changes nothing.
3. **A CLI can be taken off a host.** `CLIS_REMOVE` names CLIs to remove — the
   binary in `~/.local/bin` and the directories `CLI_DATA_<NAME>` in
   `install.conf` names, relative to the account's home, then the parents they
   leave empty. A path that leaves the home is refused. A CLI may not be both
   installed and removed.
4. **Off the bridge, the agent searches through DuckDuckGo.** `ddgs` (MIT), the
   one search backend of the agent that needs no key, is pinned in
   `install.conf` (`HERMES_DDGS_VERSION`) and installed into the agent's own
   environment as its owner, again after an update replaces that environment.
   The run names it as `web.search_backend` alone: ddgs cannot read a page, and
   with a search backend named the agent sends `web_extract` to Firecrawl,
   which without a key walks the same keyless providers (Exa, Parallel,
   Firecrawl, Keenable, with failover on throttling) that served both before.
   A backend the operator chose stays theirs.
5. **The bridge stays in the repository** as an option for an installation
   that can use it. 0024, 0027 and 0028 describe it and stay accepted.

## Consequences

- No bot depends on a CLI's quota or sign-in any more; nothing has to be
  signed in by browser for inference. The Admin bot's `opsctl` shows the bridge
  and agy only where they exist, so their absence does not read as an outage. The key is the only credential, in the
  secrets file, saved with the rest of the host's settings in its private
  repository.
- The free tier is shared by every bot on it. Its per-minute limit counts
  tokens, so a bot's context window is set well below the model's million;
  compression keeps long chats under it.
- Outside the EEA, Switzerland and the UK the provider may use what the bots
  send on the free tier; whatever a bot must not hand to it belongs on a paid
  API there. Inside them the paid tier's data terms hold, so a bot's
  sub-agents can read private mail on the free tier.
- `CLIS_REMOVE` deletes a sign-in. The private repository keeps a copy of
  what it saved before, in its history; the removed files are taken out of its
  folder by hand, once, since `configs save` copies and never deletes.

## Alternatives considered

- **Keep the bridge, wait for the quota.** A day's outage at a time, and no
  sign that the CLI keeps serving the subscription's models.
- **Automate the web app** (a browser driven against the consumer site, or its
  session reused). Against its terms and a risk to the account; rejected.
- **A paid API for every bot.** Works, costs per use; the operator wants the
  bots free and accepts outages instead.
- **ddgs as the shared web backend.** The agent's auto-detection picks it
  once the package imports — for search and for page reads alike, and ddgs
  cannot read a page. Named for search alone instead.

# 0017 — Tool calls through the CLI bridge

## Status

Accepted. Corrects an assumption the inference design was built on.

## Context

The bridge presents a subscription coding CLI as an OpenAI-compatible endpoint.
It was designed and measured for conversation — tokens per turn, cache
behaviour, process lifetime. Tool calling was listed as unverified in the plan
(open item C-1) and then treated as settled. It was not.

Measured on the running system:

- The bridge contained no `tool_calls` at all. Every response was
  `{"role": "assistant", "content": text}` with `finish_reason: "stop"`.
- The tool definitions the gateway sends with each request were counted and
  discarded. The "57 tools" the bridge logged were the CLI's **own**.

The CLI is an agent, not a model API. Given a request that needs work it
reached for its own tools, was auto-denied because headless mode cannot prompt
for permission, and returned nothing:

```
RuntimeError: jetski: no output produced — a tool required the "command"
permission that headless mode cannot prompt for, so it was auto-denied.
```

The user saw "The model provider failed after retries." The agent could hold a
conversation and nothing else — no mail, no calendar invitation, no command,
which is most of what it exists to do.

## Options

**1 · Let the CLI act.** `permissions.allow`, or
`--dangerously-skip-permissions`. Cheapest to build. The CLI then runs commands
on the host itself, outside the gateway — so `approvals.deny`,
`unattended_mode: deny`, `cron_mode: deny` and the sender allowlists apply to
none of it. The agent reads untrusted mail; this buys capability by discarding
every constraint the installation is arranged around.

**2 · A provider with native tool calling.** Correct, and the least code. But
it replaces the subscription this deployment is built on with metered API
usage, which was the reason for the bridge in the first place.

**3 · Translate in the bridge.** Render the caller's tool definitions into a
contract, have the CLI answer with a JSON decision, convert that back into
`tool_calls`. The model decides; the gateway executes; every approval rule
still applies.

## Decision

Option 3.

Verified before building on it — the failure mode here was assuming, so the
claim is measured. Given the contract, the CLI answers:

```
{"type":"tool_call","name":"list_dir","arguments":{"path":"/etc"}}
```

rather than trying to list the directory itself.

## Cost, stated plainly

- **A schema obeyed, not a protocol implemented.** Native tool calling is
  enforced by the provider; this is a model following instructions. It will
  occasionally answer with prose. The parser therefore degrades to plain
  content rather than failing the turn — a passthrough beats a lost answer.
- **The contract is tokens.** It lists every function with its parameters. It
  lives in the system block, which is sent once per process and cached, so it
  costs at process start rather than every turn — but a large toolset makes
  starting a conversation more expensive.
- **The toolset is part of a process's identity.** A conversation arriving with
  different tools gets its own process; otherwise one holding the previous
  contract in its cache would answer with it.

## Consequences

`tests/bats/shim.bats` covers the translation, including the cases that look
easy and are not: a brace inside a string, prose around the object, a fenced
block, several calls in one decision, and text that is not a decision at all.

If the CLI's compliance turns out to be too unreliable in practice, option 2 is
still there and needs only a key — the endpoint slots are prepared in
`hermes.conf`. That is a measurement to make, not a thing to assume.

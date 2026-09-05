# 0021 — The bridge is stateless

Date: 2026-09-05 · Status: accepted (supersedes the per-conversation process pool of ADR 0017's implementation)

## Context

The bridge turns the inference CLI into an OpenAI-compatible endpoint. The CLI
is an agent of its own — its own system prompt and identity, its own tools, its
own conversation memory. Keeping one CLI conversation per chat meant the agent's
system prompt was, to the CLI, an old user message: summarised away as the
conversation grew, and absent from every fresh conversation the agent's own
history rewrites forced (compression, skill creation, session resets). The bots
then answered as the vendor's coding assistant, denied having their tools, and
switched to the formal register. Fixing each symptom was a bottomless list.

## Decision

Every request is one fresh CLI conversation: operating context, the agent's
system prompt, the transcript so far, then an identity line placed immediately
before the user's message. The CLI keeps nothing between requests, so nothing
can drift. Start-up cost is hidden by a pre-warmed process per model. The
legacy pool remains behind `--stateful` for comparison.

Position, not wording, made the identity stick: the same instruction at the
head of a 50k-token first message was ignored; one line before the question is
followed. Verified against the CLI directly before building.

## Consequences

- Prompt tokens per turn grow with the transcript; the CLI's prefix cache
  absorbs most of it (observed: cached ≈ input on repeated turns).
- No more compaction logic in the bridge's hot path; the agent's own context
  management is the only one.
- A model's own tool envelope wrapped one level too deep is unwrapped
  (`unwrap_nested_call`) instead of losing the turn.

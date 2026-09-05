# 0005 — Channels are config toggles, not rollout phases

**Status:** accepted

## Context

The agent reaches its user over several messaging platforms. An obvious approach
is to bring them up in stages — one platform first, more later once it is
settled.

That makes the deployment a sequence rather than a description, and a sequence
cannot be reproduced by running one command. It also puts the difference between
two installations in someone's memory instead of in a file.

## Decision

Every channel is an independent toggle in configuration. One run brings up
exactly the channels the configuration names. A smaller installation is a
different configuration, not an earlier phase.

Enabling a channel writes its sender allowlist in the same operation. Doing it
afterwards leaves a window in which anyone who can find the address can instruct
the agent.

## Consequences

- The configuration is the complete description of an installation.
- Bringing channels up one at a time remains possible — it is a sequence of
  configurations — but is a choice rather than a requirement.
- Every enabled channel must have its allowlist present before the run starts,
  which the validator checks rather than discovering half way through.
- Accepting messages from anyone requires an explicit setting and a
  confirmation, because it cannot be undone retroactively.

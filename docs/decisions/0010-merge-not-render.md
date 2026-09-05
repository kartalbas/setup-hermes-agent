# 0010 — Merge vendor configuration, never render it

**Status:** accepted

## Context

The agent owns its configuration files. It rewrites them during setup, during
migrations, and when pairing a channel. A provisioner that renders those files
from a template destroys whatever the agent wrote, and reports a change on every
run because the agent writes it back.

The vendor's own command handles individual scalars and routes credentials to
the right file, but it cannot express nested maps or lists — and the provider
configuration is both.

## Decision

Key-level updates for scalars, and a deep merge for structure. Maps merge key by
key; lists and scalars are replaced.

Credentials are never written into the general configuration file. They go to
the credential file and are referenced from configuration by variable name.

## Consequences

- A re-run genuinely converges, which is what makes the idempotency assertion
  meaningful.
- The general configuration file stays ordinary enough to read, quote in a bug
  report or copy somewhere less careful.
- Lists are replaced rather than extended, so a fallback chain declares itself
  rather than accumulating a copy on every run.
- The merge needs an interpreter with a YAML library; the agent's own
  environment has one, and that is preferred over the system interpreter.

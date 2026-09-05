# 0003 — Pin a revision and enforce the pin

**Status:** accepted

## Context

The vendor installer defaults to the tip of the default branch — unreleased
code. Worse for a provisioner that is supposed to be idempotent: given an
existing checkout it moves to the default branch and fast-forwards, then reports
that the requested commit is "already newer" and exits successfully.

A second run therefore drifts onto unreleased code while every check still
passes. The agent's own update command does the same thing by design.

## Decision

Pin a released revision, resolve it to a full commit hash, and enforce it:

- resolve the configured reference to a 40-character hash (abbreviated hashes
  are rejected by the installer),
- record the resolved hash,
- **skip the vendor installer entirely** when the checkout already matches the
  recorded hash and the environment imports,
- pass the flag that permits moving an existing checkout backwards when it does
  need to run.

## Consequences

- A re-run is genuinely quiet and the deployed revision is knowable.
- Upgrading is raising the configured reference and re-running.
- The agent's own updater must not be used; it is on the approval denylist so
  the agent cannot invoke it, and the runbook says so for humans.
- The skip condition is the only thing keeping the pin stable, so it is covered
  by an acceptance assertion rather than left to inspection.

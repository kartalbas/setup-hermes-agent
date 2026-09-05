# 0001 — Run the agent natively, not in a container

**Status:** accepted

## Context

The agent can run either as a normal service on the host or inside a container.
The container option is attractive because the agent writes and executes its own
code, and containment for that is worth having.

But the target is a dedicated single-purpose virtual machine. The VM is already
the isolation boundary; there is nothing else on the host to protect from the
agent. Containerising it would add containment that is already present.

The cost is concrete. The vendor's own service unit provides readiness
notification, an explicit service account, ordered shutdown and cleanup of
processes the agent spawned. Running under a container runtime replaces that
with a chain of three supervisors — init, the container runtime, and the
container's own supervisor — where the outer one can no longer tell whether the
agent is serving or merely present.

## Decision

Install natively and use the vendor's service unit.

## Consequences

- The service integrates properly with the init system, including readiness and
  a watchdog (see 0007).
- Adjustments must be made as drop-ins: the agent regenerates its own unit file
  whenever it considers it stale, so edits to the unit do not survive.
- The host acquires a language runtime and toolchain it would not otherwise
  have. On a single-purpose machine that is acceptable; on a shared one it
  would not be.
- Upgrades are a checkout move rather than an image swap, so rollback depends on
  the pin (0003) and on host snapshots rather than on image digests.

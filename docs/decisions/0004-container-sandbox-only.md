# 0004 — Containers for the sandbox only

**Status:** superseded by [0013](0013-tools-on-the-host.md)

> Superseded once the developer tools moved onto the host: an agent executing
> inside a container cannot see tools installed outside it, so the sandbox and
> the toolchain could not both be had. The reasoning below still stands on its
> own terms — what changed is the requirement it was answering.

## Context

There are two unrelated ways a container runtime meets this agent: running the
agent itself in a container, and giving the agent containers to execute its tool
calls in. Conflating them produces the worst arrangement of the two.

The agent is not containerised (0001). The second use remains valuable: the
agent writes and runs its own code, and doing that in a disposable container
rather than directly as the service account is a real reduction in what a bad
turn can reach.

## Decision

Install the container runtime and set the terminal backend to use it. The
gateway itself stays native.

Ordering matters: the runtime must be in place **before** the agent first
starts, or the agent spends its first window executing tool calls directly as
the service account — the exact thing the sandbox exists to prevent.

## Consequences

- Tool execution is confined to a container with no runtime socket, dropped
  capabilities and no inherited credentials.
- The gateway needs access to the runtime socket to arrange that, which is
  root-equivalent on the host. Acceptable on a dedicated machine, not on a
  shared one.
- Group membership is granted as a unit drop-in rather than by editing the
  account: it is visible in the unit, removed on uninstall, and avoids the
  familiar confusion where a newly added group does not apply to a running
  process.
- The sandbox image is pulled during provisioning, because a cold pull on the
  first tool call reads as the agent having hung.

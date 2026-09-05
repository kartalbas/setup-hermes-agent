# 0013 — Developer tools on the host, and no sandbox

**Status:** accepted — supersedes [0004](0004-container-sandbox-only.md)

## Context

The agent is expected to do real work on this machine: cluster operations,
infrastructure code, secret handling, repository maintenance. That needs a
toolchain — around sixty command-line tools.

Those tools have to live where the agent's commands execute. Installed on the
host they are invisible to an agent running inside a container; installed in a
container image they are invisible to an agent running on the host. There is no
arrangement in which both are true.

[0004](0004-container-sandbox-only.md) chose the container, on the grounds that
an agent which writes and runs its own code should not do so directly as the
service account. That reasoning has not become wrong. It has become
incompatible with the requirement.

## Decision

Install the tools natively, on the system path, and run the agent's commands
locally rather than in a container.

## Consequences

- The agent can actually do the work it was set up for.
- There is **no container boundary** between the agent and this machine. It runs
  as the service account, with that account's credentials, against whatever the
  host can reach.
- What is left holding the line: a dedicated account without sudo
  ([0002](0002-dedicated-service-account.md)), mandatory sender allowlists, an
  approval denylist, unattended turns denied by default, and the fact that the
  host is a single-purpose virtual machine that can be rebuilt from this
  repository.
- The credentials reachable from this machine now define the blast radius. A
  cluster credential placed here is a cluster credential the agent can use, and
  an agent that reads untrusted mail is an agent that can be argued into using
  it. Treat what is placed on this host as what the agent is trusted with.
- If that trade stops being acceptable, the way back is not the old sandbox but
  a smaller one: give the agent an `ssh` backend into a throwaway machine that
  carries the toolchain, so the tools and the execution stay together while the
  credentials do not.

# 0002 — Dedicated service account without sudo

**Status:** superseded by [0016](0016-account-with-sudo.md)

> Superseded when the operating model changed: everything is now installed and
> updated from inside the account, which an account without sudo cannot do. The
> risk this record describes is real and did not go away — 0016 states what
> replaced the mitigation.

## Context

The agent executes tool calls, writes its own skills, and runs shell commands
composed from untrusted input. Whatever account it runs as is the blast radius.

Reusing the administrator's account is tempting because it already exists and
its home directory is already set up. On a machine where that account has
passwordless privilege escalation, it also means any agent-level problem becomes
host root without a further step.

## Decision

Create a dedicated system account with no login shell and no sudo entry, and run
the service as it. `SERVICE_USER` remains configurable, so the choice is visible
rather than hard-coded.

## Consequences

- Escalation via sudo from the service tree is not merely blocked but absent.
  `NoNewPrivileges=true` is still set, as defence in depth rather than the
  primary control.
- The account still joins the container group when the sandbox is enabled
  (0004), which is root-equivalent on the host. That is the residual risk, and
  it is smaller than the one it replaces.
- Files under the data directory belong to an account nobody logs in as, so
  administrative access to them requires an explicit `sudo -u`.
- The provisioner must create the account, which means it needs root on a first
  run even when nothing else would require it.

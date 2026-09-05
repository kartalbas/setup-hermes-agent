# 0016 — The service account has sudo, and is where the work happens

**Status:** accepted — supersedes [0002](0002-dedicated-service-account.md)

## Context

[0002](0002-dedicated-service-account.md) gave the agent a dedicated account
with no login shell and no sudo, on the grounds that an account which can
escalate turns any agent-level problem into host root. That reasoning has not
become wrong.

What changed is the operating model. Everything is to be installed, configured
and updated from inside that account: the repository lives in its home, the
provisioner is run from there, and no work happens from an administrator
account. An account that cannot install anything cannot do that.

The alternative was to keep running the provisioner as an administrator and let
the agent's account stay powerless. That was rejected: it splits the work across
two accounts, and the thing being operated is then not the thing being operated
*from*.

## Decision

The account gets a login shell and passwordless sudo. `bootstrap.sh` creates it,
grants it, copies the administrator's authorised keys so it can be reached, and
places the repository in its home. Everything after that happens inside it.

## Consequences

- One account, one place, one copy of the repository. Installation and update
  are the same procedure from the same directory.
- **The chain is open again**: agent → service account → root. `NoNewPrivileges`
  on the service unit still blocks escalation from inside the *service tree*,
  which is not nothing — but a compromise that reaches an interactive shell as
  this account reaches root.
- What is left holding the line is no longer the account: it is the machine.
  This is a single-purpose virtual machine, rebuildable from this repository,
  and it should be treated as expendable rather than as trusted. Credentials
  placed on it are credentials the agent effectively holds.
- `--no-sudo` exists for anyone who wants [0002](0002-dedicated-service-account.md)
  back and is content to run the provisioner from elsewhere.
- The account's home moves out of the agent's data directory to a normal home,
  because it is now somewhere a person logs in and works.

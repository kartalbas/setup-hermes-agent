# 0015 — Everything is prepared in the repository, nothing by hand on the host

**Status:** accepted

## Context

A provisioner drifts toward a split brain. Some settings live in files it reads;
others get created on the target during the run — a generated key, a browser
sign-in, a token pasted into a system directory. Each is individually
reasonable, and together they mean the host holds state the repository does not.

That has three costs. The host stops being reproducible: rebuilding it loses
whatever was created there. The repository stops being the truth: reading it no
longer tells you what the machine is. And the operator ends up editing files in
`/etc` before the first installation has even happened, which is the point at
which "run this script" stops being an accurate description of the procedure.

## Decision

Everything the target needs is prepared in the repository first, and the run
deploys it. Concretely:

- **Values** — tokens, passwords, allowlists — in `config/secrets.conf`,
  gitignored, mode 0600.
- **Files** — SSH keys, OAuth tokens, session state — in `config/credentials/`,
  gitignored, deployed by a manifest in `config/install.conf`.
- **Keys are generated into the repository**, not onto the host, so they can be
  registered with a forge *before* the first run and survive a rebuild.
- Updates follow the same path: change the repository, run again. Nothing is
  edited in place on the target.

## Consequences

- The host is disposable. Rebuild it, run the provisioner, and it is the same
  machine — including its identity to a git forge.
- One place to look, and one place to back up. A backup of this repository plus
  the agent's data directory is the whole installation.
- Credentials sit in a working tree rather than under `/etc`, which is easier to
  leak: they are gitignored, `tests/agnostic.sh` fails the build if anything
  site-specific reaches a tracked file, and the secrets file is parsed rather
  than sourced. The exposure is real and is accepted for the reproducibility.
- Two steps genuinely cannot be moved into the repository, because they happen
  in a browser against someone else's service: authorising a CLI, and pairing a
  messaging account by QR code. Both produce a file afterwards — so both can be
  *captured* into `config/credentials/` and deployed on every subsequent run.
  The manual step happens once per credential, not once per installation.

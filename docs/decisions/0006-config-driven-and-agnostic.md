# 0006 — Config-driven, site-agnostic, enforced by test

**Status:** accepted

## Context

A provisioner written for one machine becomes useless the moment there is a
second. The usual failure is not a decision to hard-code anything, but accretion:
a hostname here, an account name there, each individually reasonable.

Declaring the code "site-agnostic" in a README does not keep it that way.

## Decision

All site data lives in configuration; the code carries none. This is enforced by
a test with two independent mechanisms:

- an **allowlist** of external hosts the code may reference. Adding one means
  editing the allowlist, which appears in review as a deliberate act.
- a **denylist built from the machine the test runs on** — the current account,
  the hostname, the git identity, and every host named in the live
  configuration — checked against the files that would be committed.

The allowlist catches hosts nobody vetted. The denylist catches your own.

## Consequences

- "Agnostic" is a property that fails the build, not an aspiration.
- The check is meaningful precisely because the live configuration is not
  committed: it can read real values and assert they never appear in tracked
  files.
- Two files necessarily enumerate hostnames — the allowlist and the test itself
  — and are excluded from the scan. They are the control and are reviewed as
  such.
- Test fixtures must use reserved documentation names and address ranges, since
  anything else trips the check. This is a feature.

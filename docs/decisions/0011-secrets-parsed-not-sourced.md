# 0011 — Parse the secrets file, never source it

**Status:** accepted

## Context

Configuration is bash and is sourced, which is what makes it expressive. Doing
the same to the credential file looks consistent and is much simpler than
parsing.

It is also a way to execute arbitrary code. A token is an opaque byte string
that may legitimately contain a dollar sign, a backtick or a semicolon. Sourcing
a file containing `TOKEN=$(...)` runs it.

## Decision

The credential file is read line by line against a strict `KEY=value` pattern,
with one layer of quotes stripped and the remainder taken literally. Anything
that does not match is an error rather than a guess.

Additionally: the file must be mode 0600, credentials never appear on a command
line where other users could read them from the process list, and every loaded
value is registered for redaction in log output.

## Consequences

- A credential containing shell metacharacters is stored correctly and executes
  nothing. This is covered by tests that would create a marker file if it ever
  regressed.
- The file format is narrower than shell syntax: no interpolation, no
  conditionals, no comments after a value.
- Configuration is still sourced, so it is checked for group and other write
  permission before being read.

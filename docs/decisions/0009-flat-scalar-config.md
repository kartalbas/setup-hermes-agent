# 0009 — Flat scalars, not bash associative arrays

**Status:** accepted

## Context

Several settings are naturally records: an endpoint has a name, a URL, a model
and a credential reference. The obvious encoding is an associative array per
endpoint.

It does not survive contact with the rest of the design:

- an array declared in a file that is sourced from inside a function is local to
  that function and vanishes when it returns,
- environment variables cannot carry an array, so the documented precedence
  "flag > environment > file" would be false for exactly the interesting keys,
- iterating an unknown number of them requires name references, which are
  fragile under `set -u` and awkward to unit-test.

## Decision

Flat scalars with a numeric infix: `LLM_ENDPOINT_1_BASE_URL` and so on, with a
count. Same shape for channels.

## Consequences

- The documented precedence holds for every key without exception.
- Settings are greppable, overridable from the environment, and trivial to
  validate.
- Configuration files are more verbose, which is an acceptable price for a file
  whose entire job is to be read by a human.

# 0007 — Enable the systemd watchdog explicitly

**Status:** accepted

## Context

The vendor's generated unit is `Type=simple` by default. Under that type the
init system knows only that a process exists — not whether it is doing anything.
An agent that is wedged, deadlocked or stuck retrying a dead provider looks
exactly like a healthy one.

The unit becomes `Type=notify` with a watchdog only when a watchdog interval is
configured. It is available, but it is not the default.

## Decision

Set a watchdog interval, and do it **before** the unit is generated, since that
setting is what selects the unit type.

## Consequences

- The init system can distinguish "running" from "serving", and restarts an
  agent that stops reporting.
- The unit type is verified after installation rather than assumed, and a unit
  that came out as `simple` is reported as such.
- A slow but legitimate operation could trip the watchdog if the interval is set
  too tightly; the default leaves generous margin.

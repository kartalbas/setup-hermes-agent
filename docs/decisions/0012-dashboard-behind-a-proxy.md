# 0012 — Publish the dashboard only behind a proxy

**Status:** accepted

## Context

The agent has a web interface that displays and edits configuration, including
credentials. It binds to loopback, and the vendor advises against publishing it
directly.

Reaching it from another machine is nevertheless a normal requirement. The
straightforward approach — binding it to a routable address — puts an
unauthenticated credential editor on the network.

## Decision

Leave the interface on loopback. Where it must be reachable, place an
authenticating reverse proxy in front of it, bound to one named address.
Binding to every interface is refused by the validator.

The credentials come from the credential file; there is no default and no
prompt, so a published interface without authentication cannot be produced by
omission.

## Consequences

- The interface is never itself exposed; what is exposed is a proxy that
  requires credentials.
- Over plain HTTP the password and everything the interface displays cross the
  network in clear text. The run says so rather than leaving it implied.
- One more service to keep running, and the packaged default site of that
  service must be disabled because it claims the same port.
- Where no proxy is configured, the run prints the port-forwarding command
  instead — which needs no additional service at all.

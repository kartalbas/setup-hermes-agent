# 0008 — Tunnel for webhook channels, API-driven

**Status:** accepted

## Context

Most channels are outbound: the agent polls or holds an outbound connection, and
the host needs no inbound access at all. Some platforms instead deliver by
posting to a public HTTPS address, which a private host cannot offer.

The alternatives were a reverse proxy on a real domain with certificates, or a
tunnel daemon that dials out and receives traffic over that connection.

## Decision

Use an outbound tunnel, configured through the provider's API so the whole thing
is unattended, with an assisted mode for when an API token is not available.

Publish exactly one path, with everything else answering 404.

## Consequences

- No inbound port is opened on the host, and no certificate or DNS record is
  operated locally.
- A dependency on the tunnel provider, and one more daemon to keep running.
- The published endpoint is unauthenticated at the network layer — the platform
  authenticates per request — so narrowing it to a single path is the available
  control, and unattended turns are denied approval by default.
- The tunnel and its DNS record are **not** removed on uninstall: they live in
  an account this provisioner does not own, and something else may point at
  them.
- Idempotency needs care: a tunnel with the configured name is reused rather
  than duplicated, and the DNS record is updated in place rather than appended.

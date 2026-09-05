# Verified constraints

Facts the design depends on, each with how it was established and when. Anything
not verified is marked as such and must be checked before it is relied on.

This file exists because several early assumptions turned out to be wrong — a
memory estimate, a command-line flag that did not exist, a supported platform
inferred absent from a marketing summary, and a default that was the opposite of
what was assumed. Provenance is cheaper than rediscovery.

## The agent

Verified 2026-09-03 against the vendor's published documentation and its source.

| Fact | Consequence |
|---|---|
| The interpreter requirement is a bounded range, and a current distribution's system interpreter can sit **above** it. | The bundled environment is mandatory. Never install into the system interpreter, and never disable the virtual environment. |
| The package index lags the source repository by weeks. | The package registry is not a valid installation path. |
| The installer takes a full-length commit hash only; abbreviated hashes are rejected. | References are resolved to 40 characters before being passed. |
| The installer has no flag for a tag or version, and defaults to the tip of the default branch. | The provisioner resolves the reference itself. See [0003](decisions/0003-pin-a-revision.md). |
| On an existing checkout the installer moves to the default branch and fast-forwards, then reports the requested commit as "already newer" and exits successfully. | The pin drifts silently unless the installer is skipped when the checkout already matches. |
| After setup the installer offers to install a background service, and under non-interactive operation that prompt takes its default, which is yes. It installs a **user-scope** unit. | The installer is run without a controlling terminal, and the absence of a user-scope unit is asserted afterwards. Two services on one data directory corrupt its stores. |
| The installer will install a browser automation stack, including privileged package operations, unless told not to. | Skipped by default; enabled deliberately. |
| The generated unit is `Type=simple` unless a watchdog interval is configured. | The watchdog is set before the unit is generated. See [0007](decisions/0007-watchdog-opt-in.md). |
| The generated unit disables start rate limiting entirely. | A failing service retries indefinitely; bounded by a drop-in. |
| The agent regenerates its own unit file when it considers it stale. | Only drop-ins survive. Never edit the unit. |
| The service subcommands accept a scope flag and a run-as-user flag; the **installer** does not. | Distinguish the two when reading documentation. |
| The default unit scope is per-user, not system. | A system unit must be requested explicitly. |
| Configuration and credentials are separate files, both owned and rewritten by the agent. | Merge, never render. See [0010](decisions/0010-merge-not-render.md). |
| The vendor command handles scalars and routes credentials automatically, but cannot express nested maps or lists. | Structure is merged directly. |
| Sender allowlists are a first-class feature per channel. | Allowlists are mandatory rather than bolted on. |
| Channels divide into outbound (polling, outbound connections) and webhook-driven. Only the latter need inbound access. | The tunnel is required only when a webhook channel is enabled. See [0008](decisions/0008-tunnel-for-webhooks.md). |
| The mail adapter authenticates with a password only — it speaks no modern token flow — but explicitly supports pointing at a local relay. | Where a provider has disabled password authentication, a local relay is the way through. The provisioner probes a real login before writing configuration. |
| Outbound attachments are supported. | Calendar invitations can be sent as attachments, which keeps calendar write access away from the agent entirely. |
| The backup command snapshots databases through the database's own interface and excludes write-ahead logs, lock files and process state. | An archive tool used on a running installation captures torn databases. Use the vendor command. |
| The web interface binds to loopback and the vendor advises against publishing it. | See [0012](decisions/0012-dashboard-behind-a-proxy.md). |
| The agent's own update command returns the checkout to the default branch. | It must never be run. It is on the approval denylist so the agent cannot invoke it either. |

## The platform

| Fact | Consequence |
|---|---|
| The container runtime's repository does not always publish a suite for a distribution release on its launch day, and derivatives report their own codename while keeping the upstream one in a separate field. | The suite is probed and falls back, and the upstream codename is preferred. |
| The compose plugin's version numbering skipped two major versions. | Any check matching the old major reports a working installation as broken. Compare numerically. |
| The default container log driver does not rotate. | Rotation is configured before the daemon first starts. |
| Default bridge address pools overlap ranges commonly used by corporate networks and VPNs. | The pool base is configurable and set away from them. |
| The packaged default site of the web server claims the same port as the published interface. | It is disabled when the interface is published. |

## Shell behaviour the code depends on

Established by direct experiment; each has cost a bug at least once.

| Fact | Consequence |
|---|---|
| A pipeline runs each element in a subshell, so a function invoked through a pipe cannot report a change to its caller. | Content is passed by here-string or heredoc, never piped. A test enforces this. |
| A restrictive field separator suppresses splitting on spaces, so a space-separated list read from configuration is treated as one item. | Deliberate splitting sets the separator locally. This silently disabled a security denylist once. |
| Arithmetic evaluation returns a non-zero status when the expression evaluates to zero, so a post-increment from zero aborts a script under error-exit. | Increments use assignment form. |
| A conditional as the last statement of a function becomes that function's exit status, aborting the caller under error-exit when the condition is false. | Such functions end with an explicit success. |
| The dry-run wrapper shares a name with the unit-test framework's own command, which silently produces empty results rather than an error. | The framework's version is preserved under a second name before the libraries load. |

## The CLI bridge — measured 2026-09-04

| Fact | Consequence |
|---|---|
| A fresh CLI process re-sends its whole toolset (57 tool definitions, ~14k tokens) uncached on every invocation. | Spawning per request costs ~14k tokens regardless of how trivial the question. |
| A persistent process fed through stream-json accumulates a cached prefix: turn deltas of ~5.9k with cache_read growing 0 → 8.1k → 16.2k. | A living process per conversation is roughly 2.4× cheaper per turn, and the gap widens. This is why the bridge holds processes rather than spawning them. |
| Resuming a stored conversation in a *new* process (`--conversation`) does **not** restore the cache: cache_read stays flat while input grows ~14k per turn. | Resume is more expensive than starting fresh. Only a living process helps. |
| In stream-json mode the CLI continues the most recent conversation belonging to its **working directory**. | Processes sharing a directory inherit each other's history — observed as a fresh process reporting turn 5 with 24k already cached. Each gets its own temporary directory. |
| A tool whose permission is denied ends the turn with success and an empty response. | The bridge reports that as a named permission error rather than an unexplained blank. |
| Permission rules are `permission(target)`, and the permission name is not the tool name — `read_url(*)` governs the `read_url_content` tool. | An allowlist written from tool names silently grants nothing. |
| ~239 MB resident per live conversation. | Six concurrent conversations is what 7 GB tolerates beside everything else. |
| Video platforms answer plain fetches from datacentre addresses with a bot interstitial rather than content. | Transcript extraction needs a real downloader, optionally with a signed-in cookie jar — not a URL fetch. |

## Mail

| Fact | Consequence |
|---|---|
| Verified against the servers themselves on 2026-09-05, with no credentials: `outlook.office365.com` advertises `AUTH=XOAUTH2 LOGINDISABLED` and answers a login attempt with "Basic authentication is disabled."; `imap.gmail.com` advertises `AUTH=PLAIN` and answers with "Invalid credentials". | The capability list settles this in seconds and needs no password — worth doing before anyone spends time generating an app password that cannot work. |
| Basic authentication for IMAP is disabled across all tenants of the primary provider, and the vendor states that neither the customer nor its support can re-enable it. App passwords *are* basic authentication. | An app password does not rescue that mailbox. See [0014](decisions/0014-mailbox-on-a-second-provider.md). |
| The adapter documents pointing IMAP and SMTP at `127.0.0.1`. | A local OAuth relay is the supported route back, if free/busy is wanted later. |

## Unverified

- Whether hosted providers can be driven concurrently rather than as an ordered
  fallback chain. The configuration models a chain; concurrency is not claimed.
- Whether attachment paths resolve correctly when tool execution happens inside
  the sandbox, since files land in a mirrored directory.
- Whether a given mail provider permits password authentication for this
  purpose. The provisioner probes rather than assumes.

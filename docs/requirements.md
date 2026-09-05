# Requirements

Numbered so decision records and tests can cite them. "Must" is a gate on the
acceptance test; "should" is a preference that may be traded away with a reason.

## Functional

| # | Requirement |
|---|---|
| R-01 | One configuration file set describes an installation completely. Running the provisioner once produces that installation. |
| R-02 | The run is idempotent: a second run converges and changes nothing that already matches, including not restarting the service. |
| R-03 | The agent is installed at a pinned, recorded revision, and the pin survives re-runs. |
| R-04 | The agent runs as a service that starts at boot without anyone logging in. |
| R-05 | Any number of inference endpoints can be configured, self-hosted or hosted, with an ordered fallback chain. |
| R-06 | Each messaging channel is independently enabled, and enabling one writes its sender allowlist in the same operation. |
| R-07 | Channels that receive webhooks work without opening an inbound port on the host. |
| R-08 | The agent's tool execution is confined to a disposable sandbox rather than running directly as the service account. |
| R-09 | The agent's accumulated state is backed up on a schedule, using a method that produces consistent database snapshots. |
| R-10 | The installation can be removed. State survives removal unless explicitly purged. |
| R-11 | Upgrading is raising the configured revision and re-running; downgrading is the same in reverse. |
| R-12 | The web interface is reachable from another machine without being published unauthenticated. |

## Non-functional

| # | Requirement |
|---|---|
| N-01 | No site-specific value — hostname, address, account, credential — appears in any tracked file. Enforced by a test, not by review. |
| N-02 | Credentials live in one gitignored file at mode 0600, and are referenced from configuration by variable name only. |
| N-03 | A credential is never written to a command line, never logged, and never stored in the general configuration file. |
| N-04 | Every mutation is previewable: a dry run shows what would happen and changes nothing, and works without elevated privileges. |
| N-05 | Invalid configuration is rejected before anything is modified, reporting every problem in one pass, by name, with the legal values. |
| N-06 | Failures name the file, line and command, and the module that was running. |
| N-07 | Two concurrent runs cannot interleave. |
| N-08 | Libraries are sourceable without side effects, so they can be unit-tested directly. |
| N-09 | The service account cannot escalate privileges through the mechanisms the provisioner itself installs. |
| N-10 | Content written into files the agent owns is merged, never rendered from a template. |

## Explicitly out of scope

- Operating the inference endpoints. They are a dependency, reached over the
  network and verified during preflight.
- Provisioning the host itself: the operating system, its network, its
  snapshots. This configures a host that already exists.
- Managing platform-side registrations — creating bots, registering application
  identities, obtaining credentials. The provisioner consumes those; a human
  obtains them.
- Certificates and DNS for the published interface. Where transport security is
  required beyond what a tunnel provides, it is arranged outside this tool.

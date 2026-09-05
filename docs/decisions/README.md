# Decision records

One file per decision that would otherwise have to be re-argued. Each states
what was decided, why, and what it costs — the last part being the one that is
usually missing when someone revisits the choice a year later.

Status is `accepted`, `superseded by NNNN`, or `proposed`.

| # | Decision | Status |
|---|---|---|
| [0001](0001-native-not-containerised.md) | Run the agent natively, not in a container | accepted |
| [0002](0002-dedicated-service-account.md) | Dedicated service account without sudo | superseded by 0016 |
| [0003](0003-pin-a-revision.md) | Pin a revision and enforce the pin | accepted |
| [0004](0004-container-sandbox-only.md) | Containers for the sandbox only | superseded by 0013 |
| [0005](0005-channels-as-toggles.md) | Channels are config toggles, not rollout phases | accepted |
| [0006](0006-config-driven-and-agnostic.md) | Config-driven, site-agnostic, enforced by test | accepted |
| [0007](0007-watchdog-opt-in.md) | Enable the systemd watchdog explicitly | accepted |
| [0008](0008-tunnel-for-webhooks.md) | Tunnel for webhook channels, API-driven | accepted |
| [0009](0009-flat-scalar-config.md) | Flat scalars, not bash associative arrays | accepted |
| [0010](0010-merge-not-render.md) | Merge vendor config, never render it | accepted |
| [0011](0011-secrets-parsed-not-sourced.md) | Parse the secrets file, never source it | accepted |
| [0012](0012-dashboard-behind-a-proxy.md) | Publish the dashboard only behind a proxy | accepted |
| [0013](0013-tools-on-the-host.md) | Developer tools on the host, no sandbox | accepted |
| [0014](0014-mailbox-on-a-second-provider.md) | Mailbox with a second provider | accepted |
| [0015](0015-everything-in-the-repository.md) | Everything prepared in the repository | accepted |
| [0016](0016-account-with-sudo.md) | Service account has sudo, and is where work happens | accepted |

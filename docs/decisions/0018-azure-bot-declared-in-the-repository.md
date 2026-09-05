# 0018 — The Azure Bot is declared in the repository; Entra apps are verified, not created

## Status

Accepted.

## Context

Teams needs an Azure Bot resource with a messaging endpoint and a Teams channel,
and an Entra app registration the bot authenticates as. Both were created in
the portal by hand. The bot ended up with its two GUIDs swapped — tenant ID in
the app field, app ID in the tenant field — which the portal accepts without
complaint. The Bot Framework then authenticates as an app that does not exist,
never posts a message, and Teams shows the bot offline. Nothing on the host
could have found this: the tunnel's request counter stayed at zero and every
local component was healthy.

The user's requirement for this project is that nothing is set up by hand that
the installer could set up, and that a rebuilt host comes back identical. Portal
clicks fail both.

## Decision

1. **The bot is declared** in `src/azure/bot.bicep` — resource, endpoint,
   single-tenant identity, Teams channel — and deployed by `src/47-azure.sh`
   with `az deployment group create`. A dry run shows the `what-if`. The
   endpoint is derived from the tunnel configuration, so the two cannot drift.
2. **The Entra app registrations are verified, never created.** Creating one
   produces a client secret that only that run would have seen. Secrets in this
   repository flow one way — from `config/secrets.conf` to the host — and a
   module that wrote a freshly minted secret back into the repository would
   invert that. So the module checks that the IDs the secrets file names exist,
   are single-tenant, and (for the mail relay) allow public client flows, and
   explains a mismatch instead of repairing it.
3. **`msaAppId` is immutable**, so convergence on an existing bot means compare,
   then either "no change" or refuse. The swapped case is recognised by name.
   Recreation deletes a resource and costs re-adding the Teams app to a chat, so
   it is behind an explicit `AZURE_BOT_RECREATE=true` that is meant to be set for
   one run.
4. **`az login` stays manual.** It is a browser step, like the inference CLI and
   the mail relay's device code. The run uses the invoking user's CLI profile
   (`~/.azure` of `$SUDO_USER`), verifies the tenant matches the secrets file,
   and otherwise prints the exact `az login --use-device-code --tenant …` to run.
5. **The Azure CLI is installed from Microsoft's apt repository** (deb822 with a
   pinned signing key), the same way as `cloudflared` — not by piping an install
   script into a root shell, which the agent's own approval denylist forbids.

## Consequences

- A rebuilt host recreates the bot exactly; the portal is no longer part of the
  build.
- Two things remain for a human: registering the two apps (once, ever) and
  `az login` (once per host, per account that runs the installer).
- `tests/bats/azure.bats` covers the identity comparison, including the swap.

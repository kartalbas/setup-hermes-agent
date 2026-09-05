# Runbook

Operating an installed agent. For setting one up, see the README.

Throughout, `<service>` is `SERVICE_NAME` from your config (default
`hermes-gateway`), and `<home>` is `HERMES_HOME`.

## Everyday checks

```bash
systemctl status <service>
journalctl -u <service> -f              # follow
journalctl -u <service> -p err -n 50    # errors only
```

The agent has its own health command, which checks things systemd cannot see —
provider reachability, configuration sanity, channel state:

```bash
sudo -u <service-user> <install-dir>/venv/bin/python -m hermes_cli.main doctor
```

## Upgrading

**Do not run the agent's own updater.** It moves the checkout back to the
default branch, which drops the pinned revision and puts unreleased code into
production without saying so. The provisioner blocks the agent from invoking it
via the approval denylist, but a human at a shell can still do it by hand.

The supported upgrade is:

```bash
$EDITOR config/hermes.conf        # raise HERMES_REF to the new tag
./install.sh --dry-run            # confirm it resolves to the expected commit
sudo ./install.sh
```

Take a VM snapshot first. Rolling back is then a snapshot restore, or lowering
`HERMES_REF` and re-running — the provisioner passes `--force-commit`, so it
will move an existing checkout backwards.

To see what is currently deployed:

```bash
cat /var/lib/hermes-provisioner/revision
git -C <install-dir> rev-parse HEAD     # should match
```

If those two disagree, something moved the checkout outside the provisioner.
Re-run `install.sh` to put it back.

## Backups

The timer runs on `BACKUP_ON_CALENDAR` with a randomised delay.

```bash
systemctl list-timers '<service>-backup*'
systemctl start <service>-backup.service     # run one now
journalctl -u <service>-backup.service -n 30
ls -1 <backup-dest>
```

Backups use the agent's own backup command, which snapshots its databases
consistently. Do not substitute `tar` on a running installation: it will capture
databases mid-write and restore stale lock and process-state files alongside
them.

### Restore

Restoring needs the gateway stopped — the data directory has a single writer,
and importing underneath a running gateway corrupts it.

```bash
sudo systemctl stop <service>
sudo -u <service-user> <install-dir>/venv/bin/python -m hermes_cli.main \
     import <backup-dest>/hermes-YYYYmmdd-HHMMSS --force
sudo systemctl start <service>
```

**Rehearse this before you need it.** Import into a throwaway location first, so
a real restore is not the first time you run the command:

```bash
sudo -u <service-user> env HERMES_HOME=/tmp/restore-test \
     <install-dir>/venv/bin/python -m hermes_cli.main \
     import <backup-dest>/hermes-YYYYmmdd-HHMMSS --force
```

## Troubleshooting

### The service will not start

```bash
systemctl status <service>
journalctl -u <service> -n 50 --no-pager
```

The unit refuses to restart after repeated failures — that is the drop-in doing
its job, not a second fault. Clear the counter once the cause is fixed:

```bash
sudo systemctl reset-failed <service>
sudo systemctl start <service>
```

The generated unit treats one exit code as a fatal configuration error and does
*not* retry it. A service that stops immediately and stays stopped usually means
bad configuration rather than a crash: check the journal for the last message
before it exited.

### The agent answers nothing on a channel

1. Is the channel enabled? `platforms.<name>.enabled` in `<home>/config.yaml`
2. Is the sender on the allowlist? A message from an unlisted sender is dropped
   silently and deliberately — that is not a bug.
3. For webhook channels (Teams, WhatsApp Cloud), is the tunnel up?
   `systemctl status cloudflared` and check the endpoint registered with the
   platform still matches `TUNNEL_HOSTNAME`.
4. For email, run the login probe by re-running the provisioner: it tests the
   mailbox login before touching configuration.

### Replies are slow or stop mid-answer

Check the provider first, not the agent:

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' \
     -H "Authorization: Bearer $TOKEN" <base-url>/models
```

With `LLM_STRATEGY=failover` a dead primary should fail over within the turn. If
it does not, the fallback is probably misconfigured — check `fallback_providers`
in `<home>/config.yaml`.

### Disk filling up

Three usual causes, in order of likelihood:

```bash
du -sh <home>/sandboxes            # container mirrors, unbounded by default
du -sh <home>                      # sessions and memory
journalctl --disk-usage            # capped by JOURNAL_MAX_USE if you set it
docker system df                   # images and stopped containers
```

`docker system prune` reclaims container space. The sandbox mirrors under
`<home>/sandboxes` are safe to remove when the agent is stopped.

### Verifying the tunnel

```bash
systemctl status cloudflared
getent hosts <tunnel-hostname>
curl -sS -o /dev/null -w '%{http_code}\n' https://<tunnel-hostname>/<path>
curl -sS -o /dev/null -w '%{http_code}\n' https://<tunnel-hostname>/anything-else
```

The second should return 404. If it does not, the ingress rules are wider than
intended — re-run the provisioner, which publishes exactly one path.

## Rotating credentials

Every credential lives in `SECRETS_FILE`. Change it there, then re-run:

```bash
sudo $EDITOR <secrets-file>
sudo ./install.sh --only channels
```

The provisioner writes the new value into the agent's `.env` and restarts the
service. Nothing needs editing inside `<home>` by hand.

Rotate the inference token if it has ever been pasted into a chat window, a
ticket, or a terminal someone else could scroll back through.

## Uninstalling

```bash
sudo ./install.sh --uninstall            # service and code; state preserved
sudo ./install.sh --uninstall --purge    # also state and the service account
```

`--purge` asks for confirmation because it deletes conversations, memory and the
skills the agent has written — the one part of the installation that cannot be
rebuilt from this repository.

The remote tunnel and its DNS record are deliberately left in place: they live in
an account this provisioner does not own, and something else may point at them.
Remove them in the provider's dashboard if nothing does.

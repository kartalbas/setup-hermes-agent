# 0025 — Move the six bots onto the Kubernetes cluster

Date: 2026-09-09 · **Status:** proposed — **supersedes [0001](0001-native-not-containerised.md)**

## Context

[0001](0001-native-not-containerised.md) chose native installation over a
container, and its argument was sound: *"the target is a dedicated
single-purpose virtual machine. The VM is already the isolation boundary; there
is nothing else on the host to protect from the agent."* That premise is what
changes. The target is now an existing Kubernetes cluster the operator already
administers — 16 GB, 8 vCPU, Vault, Redis, MongoDB, Hetzner storage, Argo CD —
and a cluster is not a single-purpose machine. The VM stops being the boundary
the moment the workload shares a control plane with anything else.

0001 also priced the move honestly and the price has not changed: the vendor
unit gives readiness notification, ordered shutdown, and cleanup of processes
the agent spawned, and a container chain takes those away. This record accepts
that bill knowingly rather than rediscovering it in production. It supersedes
0001 rather than refining it, because 0001's decision — *install natively and
use the vendor's service unit* — is reversed, not qualified.

Five other records are touched and none is overturned. [0003](0003-pin-a-revision.md)
gets stronger: the image digest is the pin, and the ~200 lines of enforcement
that exist only because the vendor installer un-pins on re-run retire.
[0007](0007-watchdog-opt-in.md) becomes void — there is no `NOTIFY_SOCKET` in a
pod and no external probe can make the statement the watchdog made.
[0010](0010-merge-not-render.md) survives intact and is what makes the
configuration design below possible. [0013](0013-tools-on-the-host.md) keeps its
logic and changes its conclusion: tools must live where the commands execute, so
they live in the image of the bots that have a terminal, and in no other image.
[0016](0016-account-with-sudo.md)'s residual risk — *"the chain is open again:
agent → service account → root"* — is closed outright, and that is the single
largest security gain here.

What follows rests on measurements taken on the running VM (`agy` is a
210,551,040-byte glibc-linked ELF; `~/.gemini` is 699 MB; the agent tree is
2.1 GB; each profile is 44–59 MB, of which 39.5 MB is a per-profile copy of the
vendor's `tirith` sandbox) and on the pinned agent's own source. Where a claim
could not be checked it appears under *Open questions*, not as a decision.

## Decision

### 1. One image built from the vendor's, one pod per bot, one home per pod

Build `FROM` the vendor image at the pinned tag rather than re-deriving it. It
already solves two things that are easy to miss: it compiles SQLite 3.53.4 from
source because Debian's 3.46.1 carries the WAL-reset corruption bug, and it bakes
the messaging extras so the Teams adapter does not pip-install itself on first
connect into a filesystem that will not survive the pod. The four patches this
repository carries into vendor source (`hermes_patch_email_folder_file`,
`hermes_patch_teams_links_file`, `hermes_patch_help_file`,
`hermes_patch_clarify_choices_file`) move into the build; they already take a
single file argument and are unit-tested that way, and a vendor bump that moves
an anchor then fails the build instead of failing a provisioner run on a machine
that has already taken the new code. `LICENSE` is MIT (Nous Research), so baking
the checkout is permitted.

Adopt the vendor image's identity: `hermes`, uid 10000, home `/opt/data`,
`HERMES_HOME=/opt/data`. It has a real `passwd` entry, which the nine sites that
resolve a home with `getent passwd … | cut -d: -f6` require, and `runAsUser` is
pinned to it. Each pod's `HERMES_HOME` **is** an agent home, not a profile inside
a `profiles/` directory — so the whole profile layer, `HERMES_CONFIG_HOME`, and
`hermes profile create --clone` dissolve. Migration copies each
`~/.hermes/profiles/<key>/` into its PVC root and rewrites the absolute paths
that name `/home/hermes` (`terminal.cwd`, and nothing else that matters).

One Deployment per bot, `replicas: 1`, `strategy: Recreate`, RWO
**block-backed** volume. Not a preference: `state.db` is SQLite in WAL mode
(`-wal` and `-shm` are live on every profile) and `gateway.sock` is a Unix socket
in the same directory, and the gateway's cross-instance guard is
`fcntl.flock(LOCK_EX|LOCK_NB)` on `gateway.lock` inside `HERMES_HOME`
(`gateway/status.py:876`). Two pods can only share an RWO volume on one node, and
there the lock is kernel-enforced and refuses the second gateway — but a
filesystem that ignores `flock` removes that protection at the same time as it
corrupts the WAL. RollingUpdate is forbidden because it deliberately starts the
new pod before the old one is gone.

Set `HERMES_TIMEZONE=Europe/Zurich` and `TZ` in every bot's env. `hermes_time.py`
resolves `HERMES_TIMEZONE`, then `config.yaml`'s `timezone`, then the server's
local time, and today it lands on the third rung only because `timedatectl` set
the host. A pod is UTC, and the symptom — every cron job and every proposed
meeting an hour or two out — appears nowhere near the cause.
Set `HERMES_GATEWAY_EXTERNAL_SUPERVISOR=1`: without it `/restart` typed in Teams
takes the detached-`setsid` branch, which dies with the container, and the bot
never comes back. Run `tini` as PID 1 unless the check under *Open questions*
says the gateway reaps its own children.

### 2. The declared configuration is a read-only managed layer, not a rendered file

The agent already ships the layer this needs. `hermes_cli/managed_scope.py`
resolves `$HERMES_MANAGED_DIR` and merges its `config.yaml` over the profile's
file per leaf key; `env_loader._apply_managed_env` loads its `.env` **last with
`override=True`**, so it wins key by key over the profile's ~500 vendor lines
without shadowing them; and `save_config` / `save_env_value` refuse to overwrite
a pinned key. So: one projected volume per bot (a ConfigMap for the declared
`config.yaml`, a Secret for the declared `.env`) mounted read-only at
`$HERMES_MANAGED_DIR`. Argo owns those keys, the agent structurally cannot
overwrite them, and nothing is rendered into the volume. That is
[0010](0010-merge-not-render.md) enforced by the vendor instead of by our
convergence code.

Two things stay writable on the PVC and must never be projected over.
`command_allowlist` is a union the agent extends: `profiles/search/config.yaml`
holds an entry this repository never wrote, with an mtime later than the last
`channels` run. Pinning it turns the operator's "Always allowed" click into a
silent no-op. And the agent's own residue — `platforms.<name>.home_channel` from
`/sethome`, `TEAMS_HOME_CHANNEL`, `install_id`, `_config_version` — is where cron
results are delivered; it exists only after a human typed a command in the chat,
and it is present in five of six live profiles. An init container performs the
allowlist union and nothing else.

`SOUL.md` and `HELP.md` are pure functions of `bot/roles/` and `bot/help/` plus a
display name: ship them as a ConfigMap and render them in the same init
container, with a checksum annotation on the pod template driving the rollout.
The managed layer is fail-open — a ConfigMap whose YAML does not parse is logged
and ignored — so `hermes doctor`'s pinned-key count belongs in the readiness
gate, or Argo will report Synced over a bot running last week's settings.

### 3. Where each installer module lands

| module | today | where it lands | risk |
|---|---|---|---|
| preflight | cgroup v2, systemd, RAM, disk, ports, commands, no shadowing user unit, plus an authenticated `/models` probe | dropped — every check is a property the scheduler owns; the `/models` probe survives as a post-sync verify Job, because a wrong key otherwise installs cleanly and fails on the first message | low |
| host | timezone, service-account assertion, directories, ufw, journal cap, tmpfiles | dropped — `TZ`/`HERMES_TIMEZONE` in the pod spec, `tzdata` asserted at build (a slim base resolves silently to UTC), NetworkPolicy for ufw, kubelet rotation for the journal cap; `work/` becomes an emptyDir so nothing needs ageing | medium |
| credentials | deploys `ssh/id_ed25519` from the repository at 0600, comparing before writing | Vault, projected at 0400 — losing the compare-then-write means a rotation lands asynchronously and restarts nothing without a checksum annotation | low |
| git | `.gitconfig`, `known_hosts` via `ssh-keyscan`, `~/.ssh/config`, all through `runuser` | image — a baked `/etc/gitconfig` and pinned host keys replace ~250 lines of convergence and a trust-on-first-use with a reviewable file; only `user.name`/`user.email` are site data | low |
| tunnel | creates the tunnel, upserts seven CNAMEs, PUTs the ingress list, enables Universal SSL; installs cloudflared | split — the API half is a manual script (only the service targets change, from `127.0.0.1:<port>` to the ClusterIP Services); cloudflared becomes a stateless Deployment, token from Vault, `--protocol http2` as an argv flag | medium |
| azure | six Entra apps, service principals, two-year secrets, `bot.bicep`, admin consent, the Planner group, six Teams zips — and writes twelve values back into `secrets.conf` | manual script on the operator's machine; the write-back pushes to Vault (see §5) | high |
| google | console steps it refuses to invent, `gcloud` sign-in, API enablement | manual script, entirely on the operator's machine — no pod needs a `gcloud` session, because the assistant authenticates with its own token file | low |
| docker | already dead here: `TERMINAL_BACKEND="local"`, `DOCKER_MANAGE=false` | deleted, not ported — it would need exactly the privileges this move removes | low |
| devtools | 22 apt packages and 42 release-fetched binaries into `/usr/local/bin`, resolved against a 60/h GitHub budget | image, pinned — and only in the images of the two bots that have a terminal. Giving a mail-reading agent `kubectl` inside the cluster it administers is a materially worse bargain than it was on a VM where you chose which kubeconfig to place | medium |
| clis | installs `agy` and `claude` per account into `~/.local/bin` | volumes, written once by a maintenance pod — never an image layer (closed source, proprietary licence). `agy` is glibc-linked x86-64, so musl and distroless-static bases are excluded for every pod that runs it | high |
| mailproxy | its own venv with **unpinned** `emailproxy`, a self-signed cert for `IP:127.0.0.1` installed into the system trust store, and a config file with two authors | Deployment + RWO volume; the certificate is reissued for the Service DNS name and its CA baked into the bot images; `emailproxy` pinned; `EMAIL_IMAP_HOST`/`EMAIL_SMTP_HOST` stop being `127.0.0.1` | high |
| agyshim | one unit on loopback, no authentication of any kind | Deployment + ClusterIP + a default-deny NetworkPolicy admitting only the six bot pods, plus a shared-secret header on the handler. The kernel-enforced loopback boundary is gone and must be replaced deliberately, not deleted | high |
| apiproxy | one unit per balanced provider; only the Secretary asks for one | sidecar in the Secretary pod — one consumer, an in-process balance cache that replicas would multiply, and the loopback `base_url` stays literally true | low |
| hermes | clones the pinned vendor tree, runs its installer detached, carries four patches, re-pins on every run | image, built from the vendor image with the patches applied at build; the pin-enforcement machinery retires with it | medium |
| profiles | `profile create --clone`, `SOUL.md`/`HELP.md`, `work/` | rewritten — one home per pod dissolves the layer; SOUL/HELP from a ConfigMap by an init container; `work/` an emptyDir with a `sizeLimit` | high |
| service | one unit per bot: `Type=notify`, `WatchdogSec=90`, `RestartPreventExitStatus=78`, `StartLimitBurst=20`, `TimeoutStopSec=70`, `ExecStopPost`, advisory `Wants=` ordering | manifests, with three losses named in *What the operator loses*. `terminationGracePeriodSeconds: 70` is faithful; the PID-namespace teardown replaces `ExecStopPost` outright; the ordering is dropped and **not** reintroduced as an init container that waits for the bridge — `Wants=` was advisory on purpose | high |
| channels | deep-merges `config.yaml`, upserts `.env`, probes IMAP for real, restarts only what it changed | mostly manifests through the managed layer (§2); the `command_allowlist` union stays an init-container write; `_email_probe` becomes an operator-run Job, because a live Exchange login inside a start path is how a mailbox problem takes Teams down with it | high |
| assistant | four MCP servers, three `ctl` wrappers, a 33 MB venv, `github-mcp-server`, four env files, three token files, three sign-ins | split four ways: code, wrappers, venv and binary to the image (`ASSISTANT_VENV` must stop defaulting to `${ASSISTANT_STATE_DIR}/venv` or the venv lands on shared storage); `m365.env`/`tasks.env` to a ConfigMap (they hold no credential); `google.env`/`github.env` to Vault; `*.token` to a volume | high |
| ops | `opsctl`, `/etc/hermes-ops.conf`, the `systemd-journal` group, and a root-side path unit that runs the installer | rewritten against `kubectl` and `argocd`; the applier becomes a separate ops-runner Deployment (see §7) | high |
| dashboard | a second process for the Secretary, nginx, htpasswd, a ufw hole | sidecar in the Secretary pod — it reads and writes the same profile directory, and that volume is single-writer by rule; nginx, htpasswd and the firewall hole are dropped, but `_dashboard_verify`'s refusal to finish when *neither* gate answers must be reimplemented or [0012](0012-dashboard-behind-a-proxy.md)'s safety property is silently gone | medium |
| site | three rendered pages on loopback nginx, behind a whole-host tunnel rule | ConfigMap plus a ~20-line static-server Deployment behind the same tunnel rule — no state, no secret, the cheapest thing here to move, and it must exist before Google's consent screen is published or refresh tokens die after seven days | low |
| backup | a generated script plus a systemd timer, `hermes backup` to a local directory, retention by name-sort | CronJob with `pods/exec` on the six gateway pods, restic to Hetzner, plus a weekly restore drill in its own namespace (see §6) | high |

`bootstrap.sh` is dropped with the host, but its property must be replaced
consciously: one `rsync` made a single directory the entire installation, secrets
included. That now splits three ways — git for the code, Vault for the static
keys, volumes for the sign-ins — and only the first two are reproducible.
`libs/99-uninstall.sh` needs fixing before it is ported: `uninstall_apply` never
calls `apiproxy_uninstall` or `ops_uninstall`, and no `mailproxy_uninstall`
exists, so the balance proxy, the applier units and the whole relay — including
the CA it added to the system trust store — survive an uninstall today, while
`tests/acceptance.sh` reports success.

### 4. Volume layout

| volume | access | who writes | what it holds |
|---|---|---|---|
| `hermes-home-<key>` ×6 | RWO, **block-backed**, 2 Gi | that bot's gateway alone; the init container at start; the backup exec | `config.yaml`, `.env`, `SOUL.md`, `HELP.md`, `state.db` + WAL, `sessions/`, `memories/`, `cron/`, `skills/`, `bin/tirith` (39.5 MB), `gateway.pid`/`.lock`/`.sock`. Measured 44–59 MB today |
| `work` ×6 | emptyDir, `sizeLimit` 2 Gi, mounted at `<home>/work` | the gateway and every command the agent runs | scratch and `TMPDIR`. Keeps the `SOUL.md` contract literally true, keeps scratch off the state volume, and dies with the pod — which is what the two-day tmpfiles rule was approximating |
| `bridge-cli-home` | RWO, ≥ 8 Gi, one per bridge replica, never shared | the maintenance pod at install; the operator's browser sign-in; the `agy` child processes | `~/.local/bin/agy` (201 MB), `~/.gemini` (699 MB today, growing ~100 MB/day in `conversations/`, `brain/` and `log/`). The binary self-updates unless `AGY_CLI_DISABLE_AUTO_UPDATE=true`, and on a shared volume the winner rewrites it under the others mid-request |
| `bridge-workdir` | emptyDir, disk-backed, `sizeLimit` 2 Gi | the bridge (`mkdtemp` per conversation) and the tools MCP server | `AGENTS.md`, `tools.json`, `calls.jsonl`, attached images. Not `medium: Memory` — the leak is known and measured, and a memory-backed emptyDir turns a slow leak into an OOMKill |
| `assistant-tokens` | RWO, 100 Mi | the m365, google and tasks MCP servers, plus every `m365ctl`/`googlectl` invocation the 15-minute inbox monitor makes | `m365.token`, `google.token`, `google-<address>.token` only. Not the venv, not the env files |
| `mailproxy-state` | RWO, 1 Gi | the relay (its token block, on its own refresh schedule) and an init container (the static half) | `emailproxy.config`, `relay.crt`, `relay.key` |
| `ops-cli-home` | RWO, ≥ 4 Gi | the maintenance pod; the `claude` binary itself on refresh | `~/.local/share/claude/versions` (412 MB for two versions; old ones are not removed, so +206 MB per update and a retention pass is needed) and the sign-in |
| `ops-runner-state` | RWO, 5 Gi | the ops runner alone | the cached git clone, the persisted Claude Code session id, change logs. Losing it costs conversation continuity, not correctness |
| `drill-home` | generic ephemeral, 2 Gi | the weekly restore-drill Job | an **empty** `HERMES_HOME`. It must be empty: `hermes import` overlays and never deletes, so importing onto a populated tree proves nothing |
| `restic-cache` | emptyDir | backup and drill jobs | index cache; losing it costs downloads |

Not volumes, by decision: the 2.1 GB agent tree, `~/.hermes/node`,
`~/.local/share/uv` (the CPython 3.11 the gateway venv symlinks into — it must
travel with the checkout or the venv's interpreter dangles), the assistant venv
and servers, `github-mcp-server`, `opsctl`, the site pages, the balance proxy.

`assistant-tokens` is RWO and the Secretary and Tasks pods are co-scheduled onto
one node by affinity, because both write `m365.token`: the Secretary's `m365`
server and the Tasks pod's `tasks` server, which imports `Auth` straight from
`m365_assistant`. Dropping `tasks` from `BOT_SECRETARY_MCP` does not fix this —
the `m365` server writes the same file. RWX for ~10 KB of tokens means standing
up NFS, CephFS or Longhorn, and `flock` across nodes is exactly what a plain NFS
export does not honour. Before any of it, `TokenStore` in
`bot/mcp/assistant_common.py` must be fixed: it reads the file once at process
start, merges into that stale dict and rewrites the whole file, and its temp path
is the constant `f"{self.path}.tmp"` — so two concurrent savers can publish a
truncated token file. That is live today with three holders on one host. Re-open
under an `flock`, merge, write to a unique temp, replace. Roughly twenty lines
and one test, and it repairs a real bug regardless of this record's fate.

### 5. The secret split

**Vault — static, nobody rewrites them, projected read-only into the pod that
needs them.** `CF_API_TOKEN`, `CF_ACCOUNT_ID`, the cloudflared tunnel token,
`AZURE_TENANT_ID`, `MAIL_CLIENT_ID`, `TEAMS_<KEY>_CLIENT_ID` and
`_CLIENT_SECRET` ×6, `TASKS_GROUP_ID`, `TASKS_ASSIGNEE_ID`,
`GOOGLE_OAUTH_CLIENT_ID`/`_SECRET`, `GITHUB_TOKEN`, `DEEPSEEK_API_KEY`,
`HERMES_LLM_KEY_1`, `EMAIL_PASSWORD`, `DASHBOARD_PASSWORD`,
`HERMES_DASHBOARD_BASIC_AUTH_SECRET`, the SSH keys, the two Argo tokens, the
restic repository password and its backend credential. The runtime policy is
per-bot and small: of that whole list, only the Google client secret (Secretary),
the GitHub PAT (GitHub bot) and each bot's own Teams and model keys ever reach a
gateway. `secrets_load` parses, never sources ([0011](0011-secrets-parsed-not-sourced.md)),
and **dies on any file whose mode has a group or other bit set** — so
`defaultMode`/`file_perms` must be 0600 explicitly, and the rendered file belongs
in a memory-backed emptyDir, not on a disk.

**Volumes — the binaries rewrite them in place, so they cannot be Secrets (a
Secret mount is read-only).** `~/.gemini/antigravity-cli/antigravity-oauth-token`
and the rest of `~/.gemini`; the `claude` sign-in; `m365.token`, `google.token`,
`google-<address>.token`; and the token block *inside* `emailproxy.config`. That
last one is a single file with two authors, which is why
`_mailproxy_significant()` exists — the split has to cut inside the file, not
around it.

**Neither — a ConfigMap.** `m365.env` and `tasks.env` hold a directory tenant id,
a public-client app id, an account address, folder names and two Planner object
ids. Nothing there is a credential, and putting them in Vault buys a lease and
nothing else.

**The gap.** Nothing in this repository writes a secret anywhere but
`config/secrets.conf`: `_secrets_append` appends and `_secrets_set` rewrites with
`sed -i`, and the azure module depends on that for twelve produced values. A
Vault-rendered file and a projected Secret are both read-only, so the run dies
with "cannot write". The manual script therefore runs against a writable local
`secrets.conf` on the operator's machine and pushes the results with
`vault kv put`; **no pod ever writes a secret.** That is new code, not a port.

### 6. Backup, and the restore drill

`hermes backup` stays the consistency primitive — it is the only thing that
snapshots the SQLite databases through the backup API with the WAL sidecars
dropped, and [constraints](../constraints.md) already makes it the rule. It must
run where the data is mounted, and with one RWO volume per bot that means the
nightly CronJob holds `pods/exec` on the six gateway pods, on its own
ServiceAccount and never the Admin bot's. It then filters, pushes with restic to
Hetzner, and verifies.

Three things must change with the move, not after it. First, the success signal
is meaningless today: `run_backup` prints "Backup incomplete" and returns
normally, and both of the last two nights skipped twelve files while the unit
logged "Deactivated successfully". The job must assert on the reported counts,
then open its own artefact — member count, `PRAGMA integrity_check` on every
extracted database — while tolerating the known skip class (`gateway.sock` and
the loop-tick sockets). Second, the archive is mostly regenerable: of 605 MB
uncompressed, the irreplaceable set is about 35 MB. Keep skills, the databases,
sessions, cron, `config.yaml`, `.env`, `SOUL.md`, `HELP.md`, memories; drop
`node/`, every `bin/`, logs, caches, `models_dev_cache.json` and `work/` (which
the emptyDir removes from the archive by construction). Third, restic rather than
rclone, for `check`, encryption at rest on storage the operator does not own, and
atomic `forget --prune`; `--keep-daily 14 --keep-weekly 8 --keep-monthly 6`.

Add the ~24 KB that no backup contains today and that no automation can
recreate: the assistant tokens, the `agy` OAuth token, `settings.json` and
`mcp/`. Losing them costs a browser session per identity, and every one of those
sign-ins is manual by decision. They are live refresh tokens in off-site storage,
which is a real exposure; restic's encryption is the minimum condition, and the
operator should say yes to it deliberately.

The weekly restore drill is a second CronJob in its own namespace, with its own
ServiceAccount, a deny-all NetworkPolicy with one egress hole to the object
store, and an ephemeral empty home: assert every bot's newest snapshot is under
26 h old, `restic check`, restore all six, `hermes import`, then assert integrity
and non-zero counts against the manifest the backup job recorded. `hermes import`
calls `ensure_gateway_service()` when it finishes, and a restored `.env` carries
the bots' channel credentials — the vendor defuses this by returning early when
`is_container()` is true, but the drill must print what that check decided rather
than trust it, with the NetworkPolicy as the belt.

A failure has to reach the operator without depending on what is being restored:
a Kubernetes Event first, then a deadman — the drill writes a stamp on success
and the nightly job fails loudly when it is older than ten days — then a mail
through the relay. The Admin bot on Teams is the pleasant path and must never be
the only one; it runs on the volumes the drill exists to protect.

### 7. The Admin bot

`opsctl` is rewritten and the root-side applier disappears. `units()` and
`unit_line()` become `kubectl get deploy,pod -o json` (restart counts and
`OOMKilled` become first-class lines, which they never were in a journal nobody
counted); `latest_tag()` keeps working unchanged because `git ls-remote` needs
only egress, while "N commits behind" becomes Argo's `sync.revision` against the
tracked tip, which is the question that actually matters; `cmd_dry_run` becomes
`argocd app diff --revision <sha>`, a real server-side diff instead of a script
narrating its own intentions; `cmd_apply` becomes `argocd app sync`, which keeps
the two-stage property and strengthens it — Claude Code commits and pushes, Argo
reconciles, and the second stage is a server-side operation the bot merely
requests, so the admin pod being rolled by its own sync no longer kills the
operation, provided the Application carries the highest sync wave and, critically,
is on a **manual** sync policy (with `syncPolicy.automated` the push *is* the
apply and `OPS_APPLY=ask|never` become decorative, because `cmd_change` pushes
before it consults `OPS_APPLY`); `modules_for` becomes `apps-for` and must emit
**two** lists, Applications to sync and manual scripts for the operator, or the
bot will report a change as applied while the Teams package still carries the old
manifest — and while porting it, add the `libs/46-*` case it is missing today, so
a rotated credential stops mapping to nothing; `cmd_change` cannot run in the bot
pod at all, because it needs a clone, a write deploy key, the `claude` CLI and its
sign-in, the test toolchain and up to 25 minutes, and the admin gateway's toolset
is `terminal` with no container boundary since [0013](0013-tools-on-the-host.md),
so it becomes an `ops-runner` Deployment — the direct descendant of
`hermes-ops-apply.path`, one narrow door, always the same two operations, holding
the push key, the CLI volume and the Argo token, with Redis carrying the lock and
the queue and the runner's pod logs replacing `change-<ts>.log` — while the bot
itself gets a namespaced read-only Role (pods, pods/log, events, deployments,
replicasets, PVCs, configmaps, services; `metrics.k8s.io` if metrics-server
exists) with **no** verbs on secrets, no `create`/`patch`/`delete`, no
`pods/exec`, no `port-forward`, no cluster-scoped role, and an Argo account
holding `get` and `sync` but never `rollback`, because a rollback right is also a
roll-forward-to-any-revision right and rollback is the operator's escape hatch
when a change breaks the bot; `bot/roles/admin.md` is rewritten to keep the "one
instrument" rule while dropping the implication that it is a boundary — the RBAC
is the limit, the role file is not, the pod holds a cluster token that any command
the model runs can read, which is the argument for dropping `web` from
`BOT_ADMIN_TOOLSET` and removing the only untrusted-input path into that pod — and
to add the two sentences the move makes necessary: name the last good revision
when a sync goes Degraded and tell the operator to roll back in the Argo UI, and
repeat a manual cloud-side step verbatim instead of reporting the change as
applied.

### 8. What stays a manual script, in order

Everything cloud-side runs from the **operator's own machine**, not from a pod:
nothing in the cluster needs an `~/.azure`, and an admin-capable session on a PVC
is a worse thing to own than one in a laptop keychain. `install.sh --only azure`
cannot be lifted out as it stands — preflight always runs and refuses anything
that is not a systemd host — so the scripts need a thin entrypoint that sources
`00-log`, `10-util` and `20-config` and calls the module functions directly.

1. **As the operator, at dash.cloudflare.com:** create the API token (Cloudflare
   One Connector: cloudflared → Write; Zone → Read; DNS → Edit; SSL and
   Certificates → Edit) and copy the account id. → Vault.
2. **As a tenant admin, at portal.azure.com:** register `hermes-mail-relay`,
   single tenant, public client, *Allow public client flows = Yes*.
3. **As a tenant Global or Privileged Role admin:**
   `az login --use-device-code --tenant <AZURE_TENANT_ID>`.
4. Run `scripts/azure.sh` — six Entra apps, service principals, secrets,
   `bot.bicep`, the Exchange and Graph scopes declared and consented together,
   the Planner group and Team, the six Teams packages. It writes twelve values to
   a local `secrets.conf`; push them with `vault kv put`.
5. **As a tenant admin, in the Exchange admin center:** add the five bot aliases
   to the agent's mailbox, and grant Full Access on `you@example.com` to
   `agent@example.com`. Exchange takes about an hour; the scripts must tolerate
   the lag rather than fail.
6. Run `scripts/tunnel.sh` — the tunnel, seven proxied CNAMEs, the ingress list
   pointing at the ClusterIP Services, Universal SSL, and the edge-certificate
   wait. Do not drop that wait: a missing edge cert reads exactly like egress
   filtering and cost a day.
7. Let Argo sync the site. `https://assistant.example.com/`, `/privacy` and
   `/terms` must answer 200 **before** step 8. The installer runs `assistant`
   (18th) before `site` (21st) today, which is this dependency backwards.
8. **As the agent's Google account (agent@gmail.example), in the Google
   console:** project, consent screen with the branding URLs from step 7 and
   `example.com` as an authorized domain, a Desktop OAuth client, then
   **Publish**. In Testing status refresh tokens die after seven days.
9. **As the agent's Google account:** `gcloud auth login --no-launch-browser`,
   then `scripts/google.sh` for API enablement.
10. **As the operator, in Teams:** upload the six app packages. Publishing over
    Graph needs `AppCatalog.ReadWrite.All`, which the CLI token does not carry.
11. The five sign-ins, each `kubectl exec -it` into the pod that mounts the right
    volume, because credentials are per-home and a sign-in performed anywhere
    else does not carry over:
    a. **As the agy subscription account:** `agy`, in the maintenance pod on
       `bridge-cli-home`. Then the init-container merge of the tools MCP server
       entry can run — the CLI must have written `settings.json` first, and the
       bridge reads `tools_server_configured()` exactly once at startup.
    b. **As the claude subscription account:** `claude`, on `ops-cli-home`.
    c. **As agent@example.com:** the relay's device code, read from its pod log.
    d. **As agent@example.com:** `m365ctl login`, on `assistant-tokens`.
    e. **As the agent's Google account**, then **as you@example.com in a private
       window:** `googlectl login`, on `assistant-tokens`. This one reads the
       pasted redirect from stdin, so it needs `-i` and no `runuser` wrapper.

### 9. Preconditions that are not optional

There is no CI in this repository — no `.github`, and the README tells the
operator to run `tests/run.sh` by hand. Under Argo the apply is a push, so the
test gate that `cmd_change` provides today disappears unless a workflow or a
PreSync hook runs the suite on the branch. Manifests must not land before it
does; without it the Admin bot's changes reach the cluster with nothing between
them and production, which is strictly worse than today.

Site-agnosticism ([0006](0006-config-driven-and-agnostic.md)) needs a home
before any manifest is committed. `tests/agnostic.sh` builds its denylist from
`config/hermes.conf` and `config/channels.conf` precisely because `.gitignore`
keeps them out of the tree; an overlay carrying namespace, hostnames, bucket name
and tenant id defeats the check by design. The overlay therefore lives in a
second private repository that Argo CD reads, and this repository stays agnostic.
`agnostic.sh` needs three additions regardless: image references carry no scheme,
so `check_urls` cannot see them and the allowlist stops governing where code
comes from at exactly the moment images become the deployment unit; cluster CIDRs
need a rule that still fails on the operator's own subnet; and `kind: Secret` in
a tracked file should be an outright failure, because gitleaks does not reliably
catch base64 `data:`.

## Consequences

- The sudo chain from [0016](0016-account-with-sudo.md) is closed:
  `runAsNonRoot`, `allowPrivilegeEscalation: false`, capabilities dropped, and no
  host to escalate on. This is the largest security gain of the move.
- The pin becomes a digest. `_hermes_resolve_ref`, `_hermes_at_revision`,
  `--force-commit` and `_hermes_assert_no_user_unit` retire — roughly 200 lines
  of defensive bash that exist only because the vendor installer un-pins on
  re-run, and rollback stops depending on host snapshots.
- Ports 3978–3983 stop being a shared resource. Each pod has its own network
  namespace, and the whole `_pf_ports` check disappears.
- `tests/acceptance.sh` stops being destructive. Install → sync into a throwaway
  namespace; install again → sync twice and assert unchanged `metadata.generation`
  and no new ReplicaSet, which is better evidence than a unit-file mtime; uninstall
  keeps state → delete the Application with the claims retained. Today it runs
  rarely because it needs a disposable machine; then it can run on every change.
- The GitHub rate-limit budget, the per-tool version probes and the PATH
  visibility check all go with the devtools build layer.
- The bridge is reachable by DNS, which needs two validator changes in the same
  commit as the manifests: `_validate_endpoints` allows plain `http` only on
  loopback and exempts only loopback from requiring a `TOKEN_VAR`, so
  `the bridge Service on port 8787 (path /v1)` fails validation twice, and
  `AGY_SHIM_HOST=0.0.0.0` is refused outright. Replacing that refusal with "a
  NetworkPolicy must be declared" is the change; deleting it is not.
- Turns are minutes long over a single blocking HTTP request (`--timeout` 300 s,
  `PRINT_TIMEOUT_SECONDS` 900). Any mesh, sidecar proxy or ingress between the
  bots and the bridge with a shorter idle timeout cuts live turns, and the user
  sees "the model provider failed".
- `--max-processes` is dead config in the shipped stateless mode — it is read
  only inside `_get_or_start`, which that path never reaches — so steady-state
  memory is `max_concurrent × ~239 MB`, not `max_processes × 239 MB`. Three
  concurrent turns for six bots is tight; six with a ~2 Gi pod limit is
  defensible, and higher only burns quota.
- One relay, one mailbox, five bots, and no replica story. That does not get
  better in a cluster; it just becomes visible.

## What the operator loses

- **The watchdog.** `gateway/systemd_notify.py` feeds `WATCHDOG=1` only while the
  asyncio loop wakes inside its lag budget — an internal statement about liveness
  no external probe can make. The nearest substitute is `GET /health` on the
  Teams aiohttp app, which exists only for bots with a Teams channel and catches
  only a fully blocked loop, not the case [0007](0007-watchdog-opt-in.md) was
  bought for: a gateway stuck retrying a dead provider while the loop still turns.
- **"Stop when the configuration is wrong."** `RestartPreventExitStatus=78` has
  no Kubernetes equivalent, and the vendor's own container does not solve it
  either — `docker/s6-rc.d/` holds only `main-hermes`, whose `run` is
  `exec sleep infinity`, and `dashboard`, whose `finish` keys on an unset
  variable, not on an exit code. A fatal config error becomes a CrashLoopBackOff
  that retries to a five-minute ceiling forever. `StartLimitBurst=20` goes the
  same way: "visible instead of merely noisy" becomes an alerting rule or nothing.
- **Twenty-four hours of logs.** `errors_24h` and the snapshot's warning digest
  read `journalctl --since -24h`; `kubectl logs` reaches the current container
  plus one generation. Without a log store the 07:00 report says "errors 24h: 0"
  about a pod that crash-looped overnight. Adding Loki costs RAM on a 16 GB
  cluster; a Redis-backed counter in the gateways counts only what the gateway
  classifies as an error; labelling the line "since this pod started" is honest
  and worse. Shipping the third silently is the one option that must not happen.
- **The dry run.** `install.sh --dry-run` narrated every intended change
  including the full YAML fragment. `argocd app diff` shows manifest drift, never
  merge outcomes and never the state of a file inside a PVC. For a role or channel
  change the diff shows a changed ConfigMap and nothing else.
- **The idempotency proof as something a human reads.** "79 unchanged, 0 changes,
  no restarts" becomes a template hash: correct, invisible, and inferred from pod
  ages. Have the init container write its per-key result to the volume if the
  `ok`/`--` vocabulary is worth keeping.
- **The two-minute loop.** A patch fix today is edit, `install.sh`, restart. It
  becomes commit, build, push, sync, rollout. Only the `/help` text stays cheap,
  because the patched handler reads `HELP.md` per request.
- **Half the Admin bot's remit**, and the ability to verify it. Anything touching
  Entra, Cloudflare, Exchange or the Teams package is a script the bot can neither
  run nor check.
- **`uptime`, `df` and `free`** unless metrics-server is installed, and per-PVC
  fill unless something measures it from inside the pod.
- **The kernel-enforced loopback boundary** in front of an endpoint that checks
  no token on `/v1/chat/completions`. A NetworkPolicy is a policy, not a
  namespace.
- **`kubectl exec` as a standing procedure.** Five sign-ins, the backup, and every
  live diagnosis now need it, and one of those grants is on the same six pods the
  Admin bot is deliberately kept away from.
- **VM snapshots as the rollback of last resort** ([0001](0001-native-not-containerised.md)'s
  final consequence), unless the CSI supports `VolumeSnapshot` — a crash-consistent
  block snapshot is a different guarantee from a SQLite backup and worth having
  alongside it, not instead of it.

## Open questions

Each of these blocks code, and each has a cheap way to be answered.

1. **Which storage classes exist, and is any of them RWX?** →
   `kubectl get storageclass -o yaml`, then bind a 1 Gi PVC of each access mode.
   Decides the profile volumes, the assistant-token design and the whole backup
   topology. Hetzner Cloud Volumes are RWO block; a Storage Box is not.
2. **Is there a log store?** → `kubectl get pods -A | grep -Ei 'loki|elastic|fluent'`.
   Decides whether `errors_24h` survives, degrades, or gets built.
3. **Is metrics-server installed?** → `kubectl top nodes`. Decides two lines of
   `opsctl status` and whether pod memory can be reported against limits.
4. **Is there a default-deny egress policy, and can a pod reach
   `cloudcode-pa.googleapis.com`, `login.microsoftonline.com`,
   `oauth2.googleapis.com` and `outlook.office.com`?** → run a debug pod and
   `curl`. The bridge's env filter drops `HTTPS_PROXY`, `NO_PROXY` and
   `SSL_CERT_FILE` before spawning the CLI, so an egress proxy means widening
   that filter, not setting an env var.
5. **Does `tirith` install its seccomp filter under `RuntimeDefault` with no
   added capabilities, and is it shipped in the checkout or fetched at runtime?**
   → run one bot pod and have it execute a shell command through the terminal
   tool. It fails closed, it is 39.5 MB per profile, and not one file in this
   repository mentions it — it is the only sandbox left between the agent and its
   own container.
6. **Does `hermes_cli.main gateway run` behave as PID 1?** → run it with no init,
   `SIGTERM` it mid-turn, count leftovers. On the VM `KillMode=mixed` and
   `ExecStopPost` did that job. If the answer is no, `tini`; if `tini` is not
   enough, the shutdown budget needs rethinking.
7. **Does `agy`'s browser sign-in complete over `kubectl exec -it`, or does it
   bind a loopback callback port?** → run `agy` in a pod and read what it prints.
   Everything in the bridge is downstream of this, and if it is a callback the
   procedure needs `port-forward` alongside the exec.
8. **Does the CLI still hand its own cwd to the MCP child inside a container?** →
   re-run the E8 procedure in a pod and check that `calls.jsonl` lands in the
   per-conversation directory. The whole one-global-server-entry design of
   [0024](0024-callers-tools-as-native-mcp-tools.md) depends on it.
9. **Does Argo CD here use project-scoped local accounts, and what version?** →
   `kubectl -n argocd get cm argocd-cm argocd-rbac-cm -o yaml`. An SSO-only
   instance has no obvious place for a bot identity, and `app diff --revision`
   and `status.operationState` are assumed throughout §7.
10. **Does Entra revoke the superseded refresh token for this public-client
    device-code app?** → sign in twice and try the older token. Decides whether a
    lost update on `m365.token` is merely wasteful or costs a manual re-sign-in,
    and therefore how hard the co-scheduling constraint has to be enforced.
11. **Does `hermes import` into an empty home with no vendor checkout beside it
    complete cleanly?** → run it into a throwaway directory on the VM today. It
    prints guidance implying yes; the drill cannot be written on an implication.
12. **Where does the site overlay live, and how does Argo read it?** → operator
    decision, not a measurement. Until it is answered, committing manifests is a
    regression against [0006](0006-config-driven-and-agnostic.md).
13. **Does the dashboard's Host and WebSocket Origin guard accept an Ingress
    hostname when the controller sets `X-Forwarded-Host`?** → `port-forward`
    first, which is known to work, then one Ingress; read for
    `400 Invalid Host header`. The only tested shape is nginx passing `$host`
    through unchanged.
14. **Does the cluster's 16 GB fit this?** → model it before committing. Six
    gateways at 217–283 MB RSS measured idle, the bridge at ~239 MB per live
    conversation plus a `python3` MCP child per turn, the relay, the balance
    proxy, the dashboard, plus init, maintenance and backup pods. A pod needs a
    memory limit above its worst case or the OOM killer becomes the restart
    policy.

## Effort

**55–65 engineer-days**, and roughly a third of that is decisions rather than
code. The figure is a budget, not a plan: every part of it rests on the cluster
facts in the list above, and questions 1 and 2 should be answered before anyone
commits to a number at all.

Two choices move it more than any implementation detail. If the managed-scope
design in §2 holds — and the vendor's source says it does — the configuration
seam costs days rather than weeks, because nothing has to reimplement the merge.
If `opsctl change` stays in the cluster it costs about four days for the
ops-runner alone; moving it to the operator's machine gives them back and loses
"make a change from Teams, from a phone", which is the reason the command exists.

Roughly: the image with the patches and the baked extras, 3; manifests, probes
and volumes for six bots, 3; the profile-seeding and configuration rewrite, 4;
the mail relay — certificate reissue, trust-store injection into the images, a
pinned `emailproxy`, splitting `emailproxy.config`, repeating the device-code
sign-in on a volume — 3–4; the bridge, its NetworkPolicy and the validator
changes, 3; the assistant split plus the `TokenStore` fix, 4; the ops rewrite
with the runner and the ported tests, 10–12; backup, restic and the drill, 8;
the cloud-side scripts and the Vault write-back path, 4–5; CI and the agnostic
rules, 2; the operator runbook that replaces README part 3, 3; state migration,
a parallel run and cutover, 4.

The parts that are already done and cost nothing are worth naming: `tests/python`
(six files, 1329 lines) survives verbatim, and so do `shim.bats`, `azure.bats`,
`site.bats` and `bot.bats` — 50 more tests that never touched the host.

## Alternatives considered

- **Stay on the VM.** [0001](0001-native-not-containerised.md) unchanged. It
  works today, the loop is two minutes long, and nothing above is a bug report.
  The case against it is not that it is broken but that it is one machine: the
  rollback is a snapshot, the pin is enforced by a bash guard against an
  installer that fights it, and the credentials the agent can reach are the
  credentials of a box with passwordless sudo. Worth revisiting only if the
  cluster answers to questions 1 and 5 come back badly.
- **Lift and shift: one pod running all six gateways under the vendor's s6
  supervision.** Fewer moving parts and it matches the vendor's own image, whose
  s6 tree is built for per-profile gateways registering at runtime. But it
  reinstates the shared filesystem root the port check was defending, puts six
  bots in one blast radius and one restart, and gives up the per-bot resource
  limits that are most of the point at 16 GB. Rejected — but the vendor's Phase 4
  intent was not read in full, and if they mean one container for all profiles
  the one-pod-per-bot shape deserves a second look.
- **Render `config.yaml` and `.env` from manifests.** Simpler to reason about and
  it makes Argo's status mean something. It also destroys `home_channel` for every
  bot — an opaque Teams conversation id that exists only after a human typed
  `/sethome`, present in five of six live profiles, and where every cron result is
  delivered. The symptom would be "the scheduled report never arrived", weeks from
  the cause. Refused; [0010](0010-merge-not-render.md) holds.
- **A bridge sidecar in every bot pod, to keep the loopback boundary.** It would
  leave `_validate_endpoints` untouched and keep the endpoint unreachable from
  anywhere. It also means six CLI-home volumes, six browser sign-ins, six copies
  of a 201 MB self-updating binary and six times the memory floor. One central
  bridge plus two validator rules is the smaller change.
- **A token-broker service instead of a shared token volume.** A new pod, a broker
  protocol, and `access_token()` changed in both MCP servers — 150–250 lines — and
  it still needs a volume for the refresh token, so it moves a failure domain
  rather than removing one. The `flock` fix plus co-scheduling gets the same
  safety for a tenth of the work. Revisit only if the assistant genuinely needs
  several replicas.
- **RWX for the assistant tokens.** Standing up NFS, CephFS or Longhorn for
  ~10 KB of files, when the alternative is a pod-affinity rule — and when the
  `flock` the fix depends on is exactly what a plain NFS export does not honour.
- **Drop `opsctl change` and run Claude Code from the operator's machine.** Four
  days cheaper, one fewer credential in the cluster, and no queue protocol to
  build. It costs the ability to change the system from a chat, which is the
  whole reason the Admin bot exists. Named here so it is rejected deliberately
  rather than by default.
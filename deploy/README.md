# deploy/ — this repository as a unit of the onboarding platform

A skeleton, not a finished deployment. It renders, and `deploy/gate-check.sh` asks the
same questions the platform's sandbox asks, but four things in it are stubs and the
decision to move at all is still open (`docs/decisions/0025-kubernetes-deployment.md`,
status *proposed*).

## What the platform reads

| File | Read by | Rule it must satisfy |
|---|---|---|
| `platform.yaml` | gate G1 | schema-valid `ConsumerManifest`; `name` equals the chart's name **and** the repository's basename |
| `chart/Chart.yaml` | gate G1 | same name again |
| `chart/values.yaml`, `chart/values-<env>.yaml` | gate G1 | one overlay per env declared in the manifest |
| `chart/templates/**` | gates G2, G3, G6, G7, G8 | no cluster lookups, renders, PVCs fenced, the Vault contract, no mutable image tags |
| `images/*.Containerfile` | the build plane | one image per `builds[]` entry in the manifest |
| `chart/values-<env>.yaml` `builds[]` | the release pipeline's bump | one `{name,image,tag}` pin per declared build, all at one tag |

The namespace is `setup-hermes-agent-<stage>`. The unit's name is not a preference:
G1 rejects the run when the three names disagree, and a rename after onboarding
blocks every release until the registration is rewritten too.

## The quota this unit needs

A consumer may not declare its own size — the platform assigns one and renders the
namespace's `ResourceQuota` from it, and the chart's own requests and limits have to
fit inside. Measured on the reference host over six days, with the workloads rounded
to clean figures:

| | this unit | `large` today |
|---|---|---|
| requests, cpu | 540m | 1600m |
| requests, memory | 4Gi | 4Gi |
| limits, memory | 9Gi | 8Gi |
| pods | 11 | 32 |
| persistent volume claims | 10 | 4 |

Two rows do not fit. The size row wants **`limitsMemory: 12Gi`** and
**`persistentVolumeClaims: 12`** before onboarding, not after: the seed table is
`shared/unit-size.ts` in the platform repository, the table a running installation
uses is its database, and changing it later rewrites every registration that names
that size.

Ten claims rather than one is a deliberate choice bought with that row. Each bot's
profile is its own volume, so one bot can be restored or restarted without touching
the other five.

## What the cluster answered, and what it decides

Measured on the target cluster, 2026-09-09:

| Question | Answer | What it decides |
|---|---|---|
| storage classes | one, node-local (hostpath), `Delete`, **no volume expansion** | every size below is final; the backup is the only copy |
| ingress | three classes, all served by Traefik — including the one named `nginx` | the path is stripped by a Traefik `Middleware`, never by an nginx annotation |
| certificates | `ClusterIssuer` `platform-acme`, ready | the Ingress takes the issuer from `global.clusterIssuer` |
| metrics | metrics-server running | pod CPU and memory can be reported against limits |
| logs | Loki in `observability` | the Admin bot keeps an errors-of-the-last-day view |

Node-local storage is the one that shapes the chart rather than merely informing it:

- **No expansion.** A claim cannot grow later. The bridge's CLI home is the volume
  that grows without bound — the CLI keeps every conversation, 463 MiB of them
  already — so the job that prunes it is required, not optional.
- **No replication, no snapshot, `Delete` reclaim.** A volume is one node's disk.
  The nightly backup is not a second copy, it is the only one.
- **Claims bind where their first consumer is scheduled.** On a cluster with more
  than one node, two claims of this unit can land on different machines, and the
  volume two bots share then cannot be shared at all. `nodeSelector` in
  `values.yaml` is how that is made deliberate; on a single node it stays empty and
  the ReadWriteMany claim works because both pods are on the same machine anyway —
  which is a fact about where they landed, not about the storage class.

## Resources, and why the CPU has no limit

Each gateway sits at 189 to 311 MiB and 0.004 cores; the bridge peaks at 456 MiB with
one live conversation and may hold three. The work is waiting on model APIs, so CPU
requests reserve and no CPU limit is set: throttling a turn that already takes seconds
buys nothing. Memory limits are generous because exceeding one is not throttling but a
kill, and a kill mid-turn loses the turn.

`terminationGracePeriodSeconds` is 120. A turn runs up to 300 seconds over a single
blocking request, and the default 30 would cut live turns on every rollout.

## What the chart does that the installer used to do

**The declared configuration is a read-only projection**, not a rendered file. The
agent owns `config.yaml` and rewrites it, which is why the installer merges key by key
(ADR 0010). The vendor ships a managed scope: a `config.yaml` under
`$HERMES_MANAGED_DIR` is merged over the profile's per leaf key, its `.env` is loaded
last with override, and pinned keys cannot be written back. So Argo owns those keys
and the agent structurally cannot overwrite them. Two things stay writable and must
never be projected over: the command allowlist, which the agent extends when the
operator clicks "Always allowed", and the home channel `/sethome` writes.

**The loopback boundary becomes a NetworkPolicy.** Four services bound `127.0.0.1` on
the VM and the kernel enforced it; the installer refuses `AGY_SHIM_HOST=0.0.0.0` for
that reason, because the bridge authenticates nothing. In a pod there is no loopback
left, so `templates/networkpolicy.yaml` admits only the bot pods, and the ingress
publishes the six bot paths and nothing else.

**Recreate, one replica, block storage.** The profile holds SQLite in write-ahead-log
mode and the gateway guards itself with an `flock` inside the profile. A surge pod is
refused by that lock, or — on a filesystem that ignores `flock` — corrupts the log. A
second replica would also fire every cron reminder twice.

## What is still a stub

- `images/bin/*` — `seed-profile`, `mailproxy`, `balance-proxy`, `dashboard` exit 1.
  Each has an installer module on the VM that does the work; porting them is the bulk
  of the remaining effort.
- `templates/managed.yaml` renders a minimal `config.yaml` per bot. The real one
  carries the model, delegation, toolset, tool-search, session-reset and MCP blocks
  that `libs/80-channels.sh` and `libs/62-assistant.sh` write today.
- The Admin bot has no ops runner here. In a cluster `opsctl` cannot mean journals,
  systemd and `install.sh`; ADR 0025 §7 says what it becomes.
- The maintenance job that installs `agy` and `claude` onto the CLI volume and signs
  them in is not written. It is a Job with a shell and the two volumes mounted.

## How a version reaches the cluster

Nothing here is built locally and no image is pushed by hand. The build plane
does both, on the cluster, and the chart never names a tag of its own.

1. A release is a pushed ref, `deploy/<stage>/<release-tag>`, on this repository.
   The onboarding installs the webhook and pushes the first one itself; afterwards
   the release script the platform leaves in the repository does it.
2. The webhook reaches an EventListener, which starts this unit's own Tekton
   pipeline in its build namespace. The pipeline clones at the tag, resolves it to a
   commit, and for each build declared in `platform.yaml` asks the registry whether
   that commit's image already exists — and asks the image itself, through its
   `org.opencontainers.image.revision` and `.source` labels, whether it is really
   ours. What is missing is built and pushed; what is present is reused, which is
   what makes promoting a release to a further stage one probe and one commit.
3. The **bump** then searches for every carrier of the pin grammar
   `builds[]{name,image,tag}` and writes the minted tag into each. This chart's
   `values-<stage>.yaml` is one such carrier, and it is found rather than looked up
   in a list: an image that nothing pins fails the run loudly, because a release
   nothing pins deploys nowhere.
4. The bump writes on the **delivery branch** `deploy/<stage>`, not on `master`, and
   Argo CD syncs that branch. So `master` holds the chart and the placeholder pin;
   the branch holds the chart and the real one.

Two consequences worth stating plainly. The chart resolves every image through
`builds[]` (see `_helpers.tpl`) and refuses to render without a pin — reading a tag
from anywhere else would mean the bump writes a value nothing reads, and the
deployed image would drift from the released one silently. And all declared builds
carry the same tag: one release is one image set, and the onboarding rejects a
values file that pins two.

## Checking it before dispatching a run

```bash
deploy/gate-check.sh            # the build pins, then G1, G2, G3, G6, G7, G8
deploy/gate-check.sh prod
```

The sandbox has the last word: it renders against the cluster's real value chain, runs
`kubeconform` against the target Kubernetes minor, and attests its own egress fence.
This script only spares you a round trip.

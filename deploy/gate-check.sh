#!/usr/bin/env bash
#
# The sandbox's gates, re-run locally.
#
# The onboarding platform validates this directory in a fenced sandbox and reports
# gate by gate. That is the authority. This script asks the same questions here, so a
# rejection is found before a run is dispatched rather than after — it is a
# convenience, never a substitute, and it deliberately checks only what can be checked
# from the text of a render.
#
#   deploy/gate-check.sh [stage]        default: prod
#
# G1 structure         deploy/platform.yaml parses and matches the chart and repo name;
#                      every declared env has values.yaml and values-<env>.yaml
# G2 determinism       no lookup, no .Capabilities, no .Release.IsInstall/IsUpgrade
# G3 pinned deps       dependencies are locked or vendored; the chart renders
# G6 data protection   every standalone PVC is fenced against prune and delete
# G7 secret contract   SecretStore role and server, the ServiceAccount's two alias
#                      annotations, and every ExternalSecret property declared
# G8 image discipline  no image without a tag, and none tagged latest
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
STAGE=${1:-prod}
MANIFEST=deploy/platform.yaml
CHART=deploy/chart
VAULT_URL=${VAULT_URL:-https://vault.example.com}
FAILED=0

red()   { [[ -t 1 ]] && printf '\033[0;31m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
green() { [[ -t 1 ]] && printf '\033[0;32m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
gate()  { printf '\n== %s\n' "$*"; }
bad()   { red "  FAIL  $*"; FAILED=1; }
ok()    { green "  ok    $*"; }

command -v helm >/dev/null || { red "helm is not installed — the render gates cannot run"; exit 2; }
command -v python3 >/dev/null || { red "python3 is not installed"; exit 2; }

gate "G1 structure"
if python3 - "$MANIFEST" "$CHART" "$STAGE" <<'PY'
import os, subprocess, sys, yaml
manifest_path, chart, stage = sys.argv[1], sys.argv[2], sys.argv[3]
m = yaml.safe_load(open(manifest_path))
chart_yaml = yaml.safe_load(open(os.path.join(chart, "Chart.yaml")))
name = m.get("name", "")
envs = m.get("envs") or []
remote = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
basename = remote.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git") if remote else ""

problems = []
if m.get("apiVersion") != "hostyour.cloud/v1" or m.get("kind") != "ConsumerManifest":
    problems.append("apiVersion must be hostyour.cloud/v1 and kind ConsumerManifest")
# The identity law: the unit's name is the repository's basename, and the chart's name.
if basename and name != basename:
    problems.append(f'name "{name}" != the repository basename "{basename}"')
if chart_yaml.get("name") != name:
    problems.append(f'Chart.yaml name "{chart_yaml.get("name")}" != manifest name "{name}"')
if stage not in envs:
    problems.append(f'the stage "{stage}" is not among the declared envs {envs}')
for env in envs:
    for f in ("values.yaml", f"values-{env}.yaml"):
        if not os.path.exists(os.path.join(chart, f)):
            problems.append(f"missing {chart}/{f} — every declared env needs its overlay")
for problem in problems:
    print("  FAIL  " + problem)
sys.exit(1 if problems else 0)
PY
then ok "manifest, chart name and per-env values files agree"; else FAILED=1; fi

gate "the build pins"
# Not one of the platform's gates — the release pipeline's own rule, checked here
# because it fails late otherwise. The bump writes one tag per declared build into
# values-<stage>.yaml, and one release is one image set: an image nothing pins fails
# the run loudly, and two different tags mean a corrupt delivery branch.
if python3 - "$MANIFEST" "$CHART" "$STAGE" <<'PY'
import sys, yaml
manifest_path, chart, stage = sys.argv[1], sys.argv[2], sys.argv[3]
m = yaml.safe_load(open(manifest_path))
declared = [b["name"] for b in (m.get("builds") or [])]
values = yaml.safe_load(open(f"{chart}/values-{stage}.yaml")) or {}
pins = {p.get("image"): p.get("tag") for p in (values.get("builds") or [])}
problems = []
for name in declared:
    if name not in pins:
        problems.append(f'the build "{name}" is declared but values-{stage}.yaml pins no tag for it')
extra = [i for i in pins if i not in declared]
if extra:
    problems.append(f'values-{stage}.yaml pins {", ".join(extra)}, which platform.yaml does not declare')
tags = {t for i, t in pins.items() if i in declared}
if len(tags) > 1:
    problems.append(f'the declared builds are pinned at different tags ({", ".join(sorted(tags))}) — one release is one image set')
for problem in problems:
    print("  FAIL  " + problem)
sys.exit(1 if problems else 0)
PY
then ok "every declared build is pinned, all at one tag"; else FAILED=1; fi

gate "G2 determinism"
if grep -rnE '\{\{[^}]*(\blookup\b|\.Capabilities|\.Release\.IsInstall|\.Release\.IsUpgrade)' \
      "$CHART/templates" "$CHART"/values*.yaml 2>/dev/null | grep -v '{{/\*'; then
    bad "a template depends on live cluster state or the install phase"
else
    ok "no lookup, no .Capabilities, no install-phase predicate"
fi

gate "G3 render + pinned deps"
if [[ -f $CHART/Chart.lock ]] || ! grep -q '^dependencies:' "$CHART/Chart.yaml" 2>/dev/null; then
    ok "no unlocked dependencies"
else
    bad "the chart declares dependencies without a committed Chart.lock"
fi
RENDER=$(mktemp)
if helm template gate-check "$CHART" \
        --set "global.endpoints.vault.url=${VAULT_URL}" \
        --set image.registry=registry.example.com \
        --set "stage=${STAGE}" \
        -f "$CHART/values-${STAGE}.yaml" >"$RENDER" 2>&1; then
    ok "renders for stage ${STAGE} ($(grep -c '^---' "$RENDER") documents)"
else
    bad "helm template failed"; sed -n '1,15p' "$RENDER"
fi

gate "G6 / G7 / G8 over the rendered output"
if python3 - "$RENDER" "$MANIFEST" "$STAGE" "$VAULT_URL" <<'PY'
import sys, yaml
render, manifest_path, stage, vault_url = sys.argv[1:5]
docs = [d for d in yaml.safe_load_all(open(render)) if isinstance(d, dict)]
m = yaml.safe_load(open(manifest_path))
unit = m["name"]
declared = {s["key"] for s in (m.get("secrets") or [])}
fails, oks = [], []

# G6 — a standalone PVC must be fenced against prune and delete.
pvcs = [d for d in docs if d.get("kind") == "PersistentVolumeClaim"]
unfenced = []
for d in pvcs:
    ann = ((d.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-options", "")
    if not ("Prune=false" in ann and "Delete=false" in ann):
        unfenced.append((d.get("metadata") or {}).get("name"))
fails.append(f"G6: unfenced PVCs: {', '.join(unfenced)}") if unfenced else oks.append(f"G6: all {len(pvcs)} PVCs fenced")

# G7 — the Vault contract, in three parts.
stores = [d for d in docs if d.get("kind") in ("SecretStore", "ClusterSecretStore")]
sas = {(d.get("metadata") or {}).get("name"): ((d.get("metadata") or {}).get("annotations") or {})
       for d in docs if d.get("kind") == "ServiceAccount"}
for s in stores:
    v = (((s.get("spec") or {}).get("provider") or {}).get("vault") or {})
    if v.get("server") != vault_url:
        fails.append(f"G7: SecretStore server {v.get('server')!r} != the cluster's {vault_url!r}")
    role = ((v.get("auth") or {}).get("kubernetes") or {}).get("role")
    if role != "consumer-eso":
        fails.append(f"G7: SecretStore role {role!r} != 'consumer-eso'")
    ref = (((v.get("auth") or {}).get("kubernetes") or {}).get("serviceAccountRef") or {}).get("name")
    ann = sas.get(ref)
    if ann is None:
        fails.append(f"G7: SecretStore names serviceAccountRef {ref!r}, which no rendered ServiceAccount matches")
    else:
        if ann.get("vault.hashicorp.com/alias-metadata-unit") != unit:
            fails.append(f"G7: ServiceAccount {ref} alias-metadata-unit != {unit}")
        if ann.get("vault.hashicorp.com/alias-metadata-stage") != stage:
            fails.append(f"G7: ServiceAccount {ref} alias-metadata-stage != {stage}")
if stores:
    oks.append(f"G7: {len(stores)} SecretStore checked")
want_key = f"{stage}/consumer/{unit}/app"
for es in [d for d in docs if d.get("kind") in ("ExternalSecret", "ClusterExternalSecret")]:
    for entry in ((es.get("spec") or {}).get("data") or []):
        ref = entry.get("remoteRef") or {}
        if ref.get("key") != want_key:
            fails.append(f"G7: ExternalSecret reads {ref.get('key')!r}, expected {want_key!r}")
        prop = ref.get("property")
        if prop and prop not in declared:
            fails.append(f"G7: ExternalSecret extracts {prop!r}, which platform.yaml does not declare")
    oks.append(f"G7: ExternalSecret properties all declared")

# G8 — every image reference carries a tag that is not latest, or a digest.
def images(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ("containers", "initContainers", "ephemeralContainers") and isinstance(v, list):
                for c in v:
                    if isinstance(c, dict) and isinstance(c.get("image"), str):
                        yield c["image"]
            else:
                yield from images(v)
    elif isinstance(node, list):
        for v in node:
            yield from images(v)
seen = list(dict.fromkeys(i for d in docs for i in images(d)))
mutable = [i for i in seen if "@" not in i and (":" not in i.rsplit("/", 1)[-1] or i.endswith(":latest"))]
fails.append(f"G8: mutable image references: {', '.join(mutable)}") if mutable else oks.append(f"G8: all {len(seen)} image references pinned by tag or digest")

for o in oks:
    print("  ok    " + o)
for f in fails:
    print("  FAIL  " + f)
sys.exit(1 if fails else 0)
PY
then :; else FAILED=1; fi
rm -f "$RENDER"

printf '\n'
if (( FAILED )); then
    red "gate-check FAILED — the sandbox would reject this"
    exit 1
fi
green "gate-check passed — the sandbox still has the last word"

# shellcheck shell=bash
#
# Merging structured configuration into the agent's config.yaml.
#
# `hermes config set` handles scalars and routes secrets to .env, but it cannot
# express nested maps or lists — and the provider configuration is both. Editing
# the file directly is what the vendor documents for that case.
#
# Merging, never rewriting: config.yaml is the agent's own file. It rewrites it
# during setup and migrations, and a templated overwrite would discard whatever
# it put there and make every re-run report a change.

# yaml_config_path -> the agent's config.yaml
yaml_config_path() {
    printf '%s/config.yaml' "${HERMES_CONFIG_HOME:-${HERMES_HOME:-$(getent passwd "${SERVICE_USER:-$(id -un)}" | cut -d: -f6)/.hermes}}"
}

# _yaml_python -> an interpreter that has PyYAML.
#
# The agent's own virtualenv is the reliable one: it depends on PyYAML, whereas
# the system interpreter frequently does not have it and is the wrong version
# here in any case.
_yaml_python() {
    local venv
    venv="$(hermes_install_dir)/venv/bin/python"
    if [[ -x $venv ]] && "$venv" -c 'import yaml' >/dev/null 2>&1; then
        printf '%s' "$venv"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        printf 'python3'
        return 0
    fi
    return 1
}

# yaml_merge < fragment.yaml
#
# Deep-merges a YAML fragment into config.yaml. Maps merge key by key; scalars
# and lists are replaced wholesale, which is what you want for `model:` and
# `fallback_providers:` — a fallback chain that accumulated entries across runs
# would be worse than one that is simply declared.
yaml_merge() {
    local fragment target py
    fragment=$(cat)
    target=$(yaml_config_path)

    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] merge into ${target}:"
        while IFS= read -r line; do
            [[ -n ${line//[[:space:]]/} ]] && log_info "[dry-run]   ${line}"
        done <<<"$fragment"
        return 0
    fi

    py=$(_yaml_python) || die "no interpreter with PyYAML available to edit ${target}"

    local before after
    before=$( [[ -f $target ]] && sha256sum "$target" | cut -d' ' -f1 || printf 'absent' )

    local rc=0
    HERMES_YAML_TARGET=$target HERMES_YAML_FRAGMENT=$fragment "$py" - <<'PY' || rc=$?
import os, sys, tempfile
import yaml

target = os.environ["HERMES_YAML_TARGET"]
fragment = yaml.safe_load(os.environ["HERMES_YAML_FRAGMENT"]) or {}

try:
    with open(target) as fh:
        current = yaml.safe_load(fh) or {}
except FileNotFoundError:
    current = {}

if not isinstance(current, dict):
    sys.exit("%s does not contain a YAML mapping; refusing to edit it" % target)


def deep_merge(base, incoming):
    """Maps merge recursively; everything else is replaced.

    Lists are replaced rather than extended: a fallback chain that grew by one
    copy of itself on every run would be a slow, confusing failure.
    """
    for key, value in incoming.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


import copy

before = copy.deepcopy(current)
merged = deep_merge(current, fragment)

# Compare the DATA, not the file. The agent rewrites this file itself and
# serialises it its own way; dumping an identical mapping in our style changes
# every byte and nothing else. Treating that as a change restarted the gateway
# on every run — interrupting a live agent to write back what was already there.
if merged == before:
    sys.exit(3)

directory = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".config.yaml.")
try:
    with os.fdopen(fd, "w") as fh:
        yaml.safe_dump(merged, fh, default_flow_style=False, sort_keys=False)
    if os.path.exists(target):
        stat = os.stat(target)
        os.chmod(tmp, stat.st_mode & 0o7777)
        try:
            os.chown(tmp, stat.st_uid, stat.st_gid)
        except PermissionError:
            pass
    else:
        os.chmod(tmp, 0o600)
    os.replace(tmp, target)
except BaseException:
    os.unlink(tmp)
    raise
PY

    if (( rc == 3 )); then
        log_skip "config.yaml already matches"
    elif (( rc != 0 )); then
        die "failed to merge configuration into ${target} (exit ${rc})"
    else
        after=$(sha256sum "$target" | cut -d' ' -f1)
        [[ $before == "$after" ]] || mark_changed
        log_ok "merged configuration into ${target}"
    fi

    if [[ -n ${SERVICE_USER:-} ]] && is_root; then
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$target" 2>/dev/null || true
    fi
}

# yaml_get KEY — the current value of a dotted key in config.yaml, or nothing.
# A PyYAML read costs a python start; the agent's own `config set` costs the
# whole agent's import — a hundred times more, four bots times every key on
# every run. Bools print lower-case, so "true" compares with "true".
yaml_get() {
    local target py
    target=$(yaml_config_path)
    [[ -f $target ]] || return 0
    py=$(_yaml_python) || return 0
    HERMES_YAML_TARGET=$target HERMES_YAML_KEY=$1 "$py" - <<'PY' 2>/dev/null || true
import os, yaml
with open(os.environ["HERMES_YAML_TARGET"]) as fh:
    cur = yaml.safe_load(fh) or {}
for part in os.environ["HERMES_YAML_KEY"].split("."):
    if not isinstance(cur, dict) or part not in cur:
        raise SystemExit(0)
    cur = cur[part]
if isinstance(cur, bool):
    print(str(cur).lower())
elif cur is not None and not isinstance(cur, (dict, list)):
    print(cur)
PY
}

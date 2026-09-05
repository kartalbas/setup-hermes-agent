#!/usr/bin/env bash
#
# Release the bot: move bot/VERSION, date the changelog, tag the commit.
#
#   bot/release.sh patch|minor|major        bump and release
#   bot/release.sh 1.4.0                    release exactly this version
#   bot/release.sh --dry-run <same>         show what would change
#
# Nothing is built here: the Teams package depends on the host's configuration
# and is produced by install.sh. A release is the version, the changelog and
# the git tag `bot-v<version>` — and it refuses a dirty tree or an empty
# "Unreleased" section, because a release nobody can describe is not one.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)

dry=false
[[ ${1:-} == --dry-run || ${1:-} == -n ]] && { dry=true; shift; }
[[ $# -eq 1 ]] || { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

release_bump() {            # release_bump CURRENT patch|minor|major|X.Y.Z -> next
    local cur=$1 how=$2 ma mi pa
    IFS=. read -r ma mi pa <<<"$cur"
    case $how in
        patch) printf '%s.%s.%s' "$ma" "$mi" $((pa + 1)) ;;
        minor) printf '%s.%s.0' "$ma" $((mi + 1)) ;;
        major) printf '%s.0.0' $((ma + 1)) ;;
        *)  [[ $how =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $how" >&2; return 1; }
            printf '%s' "$how" ;;
    esac
}

release_notes() {           # release_notes CHANGELOG -> the Unreleased body
    awk '/^## Unreleased/{f=1; next} /^## /{f=0} f' "$1" | sed '/^\s*$/d'
}

# Only the definitions when sourced (tests); the rest is the command.
[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0

current=$(tr -d '[:space:]' <"$here/VERSION")
next=$(release_bump "$current" "$1")
[[ $next != "$current" ]] || { echo "version unchanged: $current" >&2; exit 1; }
notes=$(release_notes "$here/CHANGELOG.md")
[[ -n $notes ]] || { echo "CHANGELOG.md has nothing under 'Unreleased'; describe the release first" >&2; exit 1; }
if ! $dry; then
    git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1 || { echo "the repository has no commits yet; commit first" >&2; exit 1; }
    [[ -z $(git -C "$repo" status --porcelain) ]] || { echo "working tree is dirty; commit or stash first" >&2; exit 1; }
    git -C "$repo" rev-parse -q --verify "refs/tags/bot-v${next}" >/dev/null && { echo "tag bot-v${next} exists" >&2; exit 1; }
fi

printf 'bot %s -> %s\n%s\n' "$current" "$next" "$notes"
$dry && exit 0

printf '%s\n' "$next" >"$here/VERSION"
today=$(date +%F)
python3 - "$here/CHANGELOG.md" "$next" "$today" <<'PY'
import sys, pathlib
p, v, d = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
s = p.read_text()
s = s.replace("## Unreleased\n", f"## Unreleased\n\n## {v} — {d}\n", 1)
p.write_text(s)
PY
git -C "$repo" add bot/VERSION bot/CHANGELOG.md
git -C "$repo" commit -q -m "bot ${next}" -m "$notes"
git -C "$repo" tag -a "bot-v${next}" -m "bot ${next}" -m "$notes"
echo "released bot-v${next} (push with: git push && git push --tags)"

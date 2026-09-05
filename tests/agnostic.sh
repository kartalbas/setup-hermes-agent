#!/usr/bin/env bash
#
# Fails if anything site-specific has reached the files that would be committed.
#
# Two mechanisms, deliberately different in kind:
#
#   1. An ALLOWLIST of external hosts (tests/agnostic.allow). Any URL pointing
#      somewhere else fails. Adding a host means editing the allowlist, which
#      shows up in review as a deliberate act rather than passing silently.
#
#   2. A DENYLIST built from the machine this runs on — the current user, the
#      hostname, the git identity, and every host named in the live config.
#      This answers the question that actually matters: "did anything from THIS
#      installation leak into the repository?"
#
# The allowlist catches hosts nobody vetted. The denylist catches your own.
# Neither is a heuristic guess at what a secret looks like; that job goes to
# gitleaks, when it is available.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

ALLOW_FILE="tests/agnostic.allow"

# These two files legitimately enumerate hostnames — the allowlist by
# definition, and this script in its own documentation. They are the control,
# and are reviewed as such.
readonly SELF_EXCLUDE=("tests/agnostic.allow" "tests/agnostic.sh")

FAILURES=0
WARNINGS=0

red()   { [[ -t 1 ]] && printf '\033[0;31m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
green() { [[ -t 1 ]] && printf '\033[0;32m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }
amber() { [[ -t 1 ]] && printf '\033[0;33m%s\033[0m\n' "$*" || printf '%s\n' "$*"; }

fail() { red   "FAIL  $*"; FAILURES=$(( FAILURES + 1 )); }
warn() { amber "WARN  $*"; WARNINGS=$(( WARNINGS + 1 )); }
ok()   { green "ok    $*"; }

# Files that would be committed: tracked, plus untracked-but-not-ignored.
# Ignored files (the real config, any secrets) are out of scope by construction.
# A line carrying this marker is not scanned. It exists for the tests that
# exercise these very checks: a classifier test has to contain examples of what
# it classifies. The exemption is per line and grep-able, so it shows up in a
# review diff exactly the way an allowlist entry does — which is the control.
# It is not for silencing a real finding.
AGNOSTIC_OPT_OUT='agnostic-ok'

# The lines of a file these checks look at. The filtering has to happen before
# extraction: what the checks iterate afterwards are matches, and a match no
# longer knows which line it came from.
_scan_lines() {
    grep -v "$AGNOSTIC_OPT_OUT" "$1" 2>/dev/null || true
}

scanned_files() {
    local f
    while IFS= read -r f; do
        [[ -f $f ]] || continue
        local skip=false s
        for s in "${SELF_EXCLUDE[@]}"; do
            [[ $f == "$s" ]] && skip=true
        done
        [[ $skip == true ]] && continue
        # Skip binaries.
        grep -Iq . "$f" 2>/dev/null || continue
        printf '%s\n' "$f"
    done < <(git ls-files --cached --others --exclude-standard 2>/dev/null)
}

# ---------------------------------------------------------------------------
# 1. External hosts must be on the allowlist
# ---------------------------------------------------------------------------

load_allowlist() {
    [[ -f $ALLOW_FILE ]] || { fail "missing $ALLOW_FILE"; return 1; }
    sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$ALLOW_FILE" | grep -v '^$'
}

host_allowed() {
    local host=$1 entry
    while IFS= read -r entry; do
        [[ -z $entry ]] && continue
        if [[ $entry == .* ]]; then
            [[ $host == *"$entry" ]] && return 0        # subdomain wildcard
        else
            [[ $host == "$entry" ]] && return 0
            [[ $host == *".$entry" ]] && return 0
        fi
    done <<<"$ALLOWLIST"
    return 1
}

check_urls() {
    local file line host found=0
    while IFS= read -r file; do
        while IFS= read -r line; do
            # Strip a scheme, then take the authority up to /, ", ', <, > or space.
            host=${line#*://}
            host=${host%%[/\"\'\<\> ]*}
            # A bracketed IPv6 literal carries its own colons, so the port can
            # only be split off after the brackets.
            if [[ $host == \[*\]* ]]; then
                host=${host%%\]*}]
            else
                host=${host%%:*}
            fi
            host=${host,,}
            [[ -z $host ]] && continue
            # Placeholders in documentation are fine.
            [[ $host == *'<'* || $host == *'>'* || $host == *'$'* ]] && continue
            # Glob metacharacters mean this is a match pattern in code, not a URL
            # (e.g. [[ $url == https://* ]]), so there is no host to check.
            [[ $host == *'*'* || $host == *'?'* ]] && continue
            # Likewise a format placeholder: "http://%s:%d/" names no host, and
            # a parameter expansion such as ${url#http://} leaves a bare brace.
            [[ $host == *'%'* || $host == *'{'* || $host == *'}'* ]] && continue
            # Loopback in any spelling is not a site address, and neither are
            # the RFC 5737 documentation ranges — the same exemption the IP
            # check makes, applied where a host arrives as part of a URL.
            case $host in
                localhost|'0.0.0.0'|'[::1]'|127.*) continue ;;
                192.0.2.*|198.51.100.*|203.0.113.*) continue ;;
            esac
            if ! host_allowed "$host"; then
                fail "$file: URL host not in $ALLOW_FILE: $host"
                found=1
            fi
        done < <(_scan_lines "$file" | grep -ohE 'https?://[^[:space:]"'"'"'<>()]+' || true)
    done < <(scanned_files)
    if (( found == 0 )); then ok "all URL hosts are on the allowlist"; fi
    return 0
}

# ---------------------------------------------------------------------------
# 2. Nothing from THIS machine may appear
# ---------------------------------------------------------------------------

build_local_denylist() {
    local -a terms=()
    local v

    v=$(id -un 2>/dev/null || true);                  [[ -n ${v:-} ]] && terms+=("$v")
    v=$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)
    [[ -n ${v:-} ]] && terms+=("$v")
    v=$(hostname -s 2>/dev/null || true);             [[ -n ${v:-} ]] && terms+=("$v")
    v=$(git config --get user.email 2>/dev/null || true); [[ -n ${v:-} ]] && terms+=("$v")
    v=$(git config --get user.name 2>/dev/null || true)
    [[ -n ${v:-} && ${#v} -ge 4 ]] && terms+=("$v")

    # Hosts and identities named in the live (gitignored) configuration.
    local cfg
    for cfg in config/hermes.conf config/channels.conf; do
        [[ -f $cfg ]] || continue
        while IFS= read -r v; do
            v=${v#*://}; v=${v%%[/:\"\' ]*}
            [[ -n $v && $v != localhost && $v != 127.0.0.1 ]] && terms+=("$v")
        done < <(grep -ohE 'https?://[^[:space:]"'"'"']+|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$cfg" 2>/dev/null || true)
    done

    # Generic values would match everything; drop them.
    local t
    for t in "${terms[@]}"; do
        case ${t,,} in
            root|user|admin|localhost|ubuntu|debian|test|none|example.com) continue ;;
        esac
        (( ${#t} < 4 )) && continue
        printf '%s\n' "$t"
    done | sort -u
}

check_local_identity() {
    local denylist file term hits found=0
    denylist=$(build_local_denylist)

    # The service account's name is site configuration that is deliberately
    # tracked (config/bootstrap.conf) and appears throughout the tree. When the
    # suite runs AS that account, `id -un` puts the name on the denylist and
    # every file "leaks" it. The name is not an identity of the machine running
    # the test; it is the product's. Drop it.
    local svc
    svc=$(sed -n 's/^BOOTSTRAP_USER="\{0,1\}\([^"#[:space:]]*\).*/\1/p' config/bootstrap.conf 2>/dev/null | head -n1)
    if [[ -n $svc ]]; then
        denylist=$(grep -vixF -- "$svc" <<<"$denylist" || true)
    fi
    [[ -z $denylist ]] && { warn "could not derive any local identity terms"; return 0; }

    while IFS= read -r term; do
        [[ -z $term ]] && continue
        while IFS= read -r file; do
            if hits=$(grep -nFi -- "$term" "$file" 2>/dev/null); then
                fail "$file: contains local identity '$term'"
                printf '        %s\n' "$(head -n1 <<<"$hits")"
                found=1
            fi
        done < <(scanned_files)
    done <<<"$denylist"

    if (( found == 0 )); then
        ok "no local identity present ($(wc -l <<<"$denylist" | tr -d ' ') terms checked)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 3. Literal addresses and mailboxes
# ---------------------------------------------------------------------------

check_ip_literals() {
    local file ip found=0
    while IFS= read -r file; do
        while IFS= read -r ip; do
            case $ip in
                127.*|0.0.0.0|255.255.255.*|0.*) continue ;;   # loopback / wildcard / masks
                192.0.2.*|198.51.100.*|203.0.113.*) continue ;; # RFC 5737 documentation
                172.30.0.0|172.17.0.0|172.31.0.0) continue ;;   # documented docker pools
            esac
            fail "$file: IP literal '$ip' — belongs in configuration"
            found=1
        done < <(_scan_lines "$file" | grep -ohE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || true)
    done < <(scanned_files)
    if (( found == 0 )); then ok "no site IP literals"; fi
    return 0
}

check_emails() {
    local file addr domain found=0
    while IFS= read -r file; do
        while IFS= read -r addr; do
            domain=${addr##*@}
            case ${domain,,} in
                example.com|example.org|example.net|*.example|*.invalid) continue ;;
                example.*) continue ;;
            esac
            # "git@forge" is an SSH login, not a mailbox — it has the shape of an
            # address but names no person and leaks nothing. Documentation cannot
            # show a clone or a key test without it. The host still has to be on
            # the URL allowlist, so this exempts the local part only.
            [[ ${addr%@*} == git ]] && continue
            fail "$file: email address '$addr' — belongs in configuration"
            found=1
        done < <(_scan_lines "$file" | grep -ohE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true)
    done < <(scanned_files)
    if (( found == 0 )); then ok "no real email addresses"; fi
    return 0
}

# ---------------------------------------------------------------------------
# 4. Secrets — delegated to a rule-based scanner rather than guessed at
# ---------------------------------------------------------------------------

check_secrets() {
    if ! command -v gitleaks >/dev/null 2>&1; then
        warn "gitleaks not installed — secret scanning skipped (install it for CI)"
        return 0
    fi
    if gitleaks detect --no-git --redact --exit-code 1 --source . >/dev/null 2>&1; then
        ok "gitleaks found no secrets"
    else
        fail "gitleaks reported findings — run: gitleaks detect --no-git --redact --source ."
    fi
}

# ---------------------------------------------------------------------------

main() {
    printf 'agnosticism check — %s\n\n' "$REPO_ROOT"

    ALLOWLIST=$(load_allowlist) || exit 1

    check_urls
    check_local_identity
    check_ip_literals
    check_emails
    check_secrets

    printf '\n'
    if (( FAILURES )); then
        red "$FAILURES failure(s), $WARNINGS warning(s)"
        printf '\nSite-specific data belongs in config/ or the secrets file, never in\n'
        printf 'tracked files. If an external host is legitimate, add it to %s\n' "$ALLOW_FILE"
        printf 'so the addition is visible in review.\n'
        exit 1
    fi
    green "passed ($WARNINGS warning(s))"
}

main "$@"

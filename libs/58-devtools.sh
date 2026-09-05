# shellcheck shell=bash
#
# Command-line tools installed natively on the host.
#
# These land in a directory on the system PATH so the service account can use
# them directly. That is deliberate: tools installed inside a container sandbox
# are invisible to an agent running on the host, and vice versa. Whichever side
# executes the agent's commands is the side that needs the tools.
#
# Consequence worth stating: with tools on the host and a local terminal
# backend, the agent runs them as the service account with that account's
# credentials — no container boundary in between. On a machine holding cluster
# or secret-store credentials, that is the whole security model.
#
# Which tools get installed lives in config/install.conf, which is tracked:
# a list of tools is not site data. Most recipes are one line — anything
# published as a GitHub release goes through _dt_gh with a template. Only tools
# with their own distribution point need a block, and those are also the ones
# publishing checksums worth verifying.

devtools_apply() {
    if ! is_true "${DEVTOOLS_MANAGE:-false}"; then
        log_skip "devtools unmanaged (DEVTOOLS_MANAGE=false)"
        return 0
    fi
    [[ -n ${DEVTOOLS_INSTALL:-} ]] || { log_skip "no tools listed in DEVTOOLS_INSTALL"; return 0; }

    log_step "Developer tools"
    require_root "installing tools into ${DEVTOOLS_BIN_DIR}"
    require_cmd curl tar

    ensure_dir "$DEVTOOLS_BIN_DIR" 0755
    _dt_apt_batch

    local tool wanted have IFS=$' \t\n'

    # One release lookup per tool that is neither an apt package nor pinned.
    local need=0
    for tool in $DEVTOOLS_INSTALL; do
        _dt_is_apt "$tool" && continue
        [[ -n $(_dt_pinned_version "$tool") ]] && continue
        need=$(( need + 1 ))
    done
    (( need > 0 )) && [[ $DRY_RUN != true ]] && _dt_github_budget "$need"

    local -a installed=() skipped=() failed=()

    for tool in $DEVTOOLS_INSTALL; do
        _dt_is_apt "$tool" && continue
        wanted=$(_dt_pinned_version "$tool")

        if have=$(_dt_installed_version "$tool"); then
            if [[ -z $wanted || $have == "$wanted" || $have == "v${wanted#v}" ]]; then
                skipped+=("$tool")
                continue
            fi
            log_info "${tool}: ${have} -> ${wanted}"
        elif [[ -z $wanted ]] && have_cmd "$tool"; then
            # Present, but its version could not be read — several of these
            # print it in a shape the probe does not match. With nothing pinned
            # there is nothing to compare against anyway, so re-downloading it
            # every run buys nothing and costs a release lookup plus an archive.
            # Pin the tool if you want a specific version enforced.
            skipped+=("$tool")
            continue
        fi

        if _dt_install "$tool" "$wanted"; then
            log_ok "${tool}"
            installed+=("$tool")
            mark_changed
        else
            failed+=("$tool")
        fi
    done

    log_info "tools          ${#installed[@]} installed, ${#skipped[@]} already current"
    if (( ${#failed[@]} )); then
        # Every tool is attempted before failing, so one run reports the whole
        # list rather than making the operator rediscover them one at a time —
        # but a configured tool that is not installed is a failure, not a note.
        log_error "could not install: ${failed[*]}"
        log_error "  usually a renamed release asset; the recipe is in src/58-devtools.sh"
        log_error "  remove the tool from DEVTOOLS_INSTALL if you do not want it"
        die "${#failed[@]} tool(s) failed to install"
    fi
    _dt_report_path
}

# ---------------------------------------------------------------------------
# Distribution packages, in one transaction
#
# Forty separate apt-get calls is forty lock acquisitions for no benefit.
# ---------------------------------------------------------------------------

_dt_apt_batch() {
    local -a want=() missing=()
    local tool IFS=$' \t\n'
    for tool in $DEVTOOLS_INSTALL; do
        _dt_is_apt "$tool" && want+=("$tool")
    done
    (( ${#want[@]} )) || return 0

    for tool in "${want[@]}"; do
        dpkg -s "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} == 0 )); then
        log_skip "distribution packages already present (${#want[@]})"
        return 0
    fi
    log_info "apt            ${#missing[@]} to install: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive run apt-get install -y "${missing[@]}"
    mark_changed
}

# Packaged well enough by the distribution that fetching them by hand would only
# cost us security updates.
_dt_is_apt() {
    case $1 in
        jq|ripgrep|fd-find|bat|fzf|tree|unzip|make|ffmpeg|git-crypt|direnv|\
        shellcheck|bats|ansible|yamllint|httpie|skopeo|pre-commit|graphviz|\
        python3-pip|python3-venv|build-essential|pkg-config) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# DEVTOOLS_PIN_KUBECTL="v1.31.0" pins one tool; empty means latest.
_dt_pinned_version() {
    local var="DEVTOOLS_PIN_${1^^}"
    var=${var//-/_}
    printf '%s' "${!var:-}"
}

_dt_installed_version() {
    local tool=$1 bin
    bin=$(command -v "$tool" 2>/dev/null) || return 1
    case $tool in
        kubectl)   "$bin" version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^"]+' | head -1 ;;
        helm)      "$bin" version --short 2>/dev/null | grep -oP 'v[0-9.]+' | head -1 ;;
        argocd)    "$bin" version --client --short 2>/dev/null | grep -oP 'v[0-9.]+' | head -1 ;;
        vault|terraform|tofu)
                   "$bin" version 2>/dev/null | head -1 | grep -oP 'v[0-9.]+' | head -1 ;;
        *)         "$bin" --version 2>/dev/null | head -1 | grep -oP 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 ;;
    esac
}

# GitHub allows 60 API calls per hour per IP unauthenticated. This module
# resolves one release per pinned-less tool, so a catalogue of this size fits
# once and a second run inside the hour does not. A token raises it to 5000.
#
# The token is written to a curl config file rather than a header argument:
# arguments are visible in ps to every account on the machine.
_dt_github_curlrc() {
    [[ -n ${_DT_GH_CURLRC:-} ]] && { printf '%s' "$_DT_GH_CURLRC"; return 0; }
    local token=""
    [[ -n ${DEVTOOLS_GITHUB_TOKEN_VAR:-} ]] && token=$(secret_get "$DEVTOOLS_GITHUB_TOKEN_VAR")
    : "${token:=${GITHUB_TOKEN:-}}"
    [[ -n $token ]] || { _DT_GH_CURLRC=""; return 0; }

    _DT_GH_CURLRC=$(mktemp)
    chmod 0600 "$_DT_GH_CURLRC"
    printf 'header = "Authorization: Bearer %s"\n' "$token" >"$_DT_GH_CURLRC"
    log_redact_register "$token"
    printf '%s' "$_DT_GH_CURLRC"
}

# Fail before installing half a catalogue, naming the real cause. Without this
# an exhausted budget surfaces as "could not resolve a release" once per tool,
# which reads like a broken recipe and sends the reader to the wrong file.
_dt_github_budget() {
    local need=$1 rc body remaining reset
    rc=$(_dt_github_curlrc)
    body=$(fetch ${rc:+--config "$rc"} https://api.github.com/rate_limit 2>/dev/null) || return 0
    # The response is pretty-printed, and grep -P matches within a line — so
    # flatten it before looking for a field inside the "core" object.
    body=$(printf '%s' "$body" | tr -d ' \n\t')
    remaining=$(printf '%s' "$body" | grep -oP '"core":\{[^}]*"remaining":\K[0-9]+' | head -1) || true
    reset=$(printf '%s' "$body" | grep -oP '"core":\{[^}]*"reset":\K[0-9]+' | head -1) || true
    [[ -n $remaining ]] || return 0

    log_info "github api     ${remaining} call(s) left, ${need} needed"
    (( remaining >= need )) && return 0

    log_error "the GitHub API budget is too small for this catalogue:"
    log_error "  ${need} release lookups needed, ${remaining} left until $(date -d "@${reset}" '+%H:%M' 2>/dev/null || printf 'the next hour')"
    if [[ -z $rc ]]; then
        log_error "  set DEVTOOLS_GITHUB_TOKEN_VAR in config/install.conf to a variable in"
        log_error "  your secrets file holding a GitHub token — that raises the limit to 5000/h."
        log_error "  A token with no scopes at all is enough; it only reads public releases."
    fi
    die "GitHub API rate limit"
}

_dt_github_latest() {
    local rc; rc=$(_dt_github_curlrc)
    fetch ${rc:+--config "$rc"} "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -1
}

# _dt_gh REPO ASSET_TEMPLATE MEMBER VERSION DEST
#
# Template placeholders, because projects disagree about every one of them:
#   %v  tag as published            v1.2.3
#   %V  tag without the leading v   1.2.3
#   %a  Go-style architecture       amd64 / arm64
#   %x  uname-style architecture    x86_64 / aarch64
#
# MEMBER names the file to lift out of an archive; empty means a bare binary.
_dt_gh() {
    local repo=$1 template=$2 member=$3 ver=$4 dest=$5
    ver=${ver:-$(_dt_github_latest "$repo")}
    [[ -n $ver ]] || { log_warn "could not resolve a release for ${repo}"; return 1; }

    local arch x asset
    arch=$(detect_arch)
    x=$([[ $arch == amd64 ]] && printf x86_64 || printf aarch64)
    asset=${template//%v/$ver}
    asset=${asset//%V/${ver#v}}
    asset=${asset//%a/$arch}
    asset=${asset//%x/$x}

    local url="https://github.com/${repo}/releases/download/${ver}/${asset}"
    case $asset in
        *.tar.gz|*.tgz|*.zip) _dt_fetch_archive "$url" "${member:-${dest##*/}}" "$dest" ;;
        *.gz)                 _dt_fetch_gz "$url" "$dest" ;;
        *)                    _dt_fetch_binary "$url" "$dest" ;;
    esac
}

_dt_fetch_binary() {
    local url=$1 dest=$2 tmp
    tmp=$(mktemp)
    if ! fetch "$url" -o "$tmp"; then rm -f "$tmp"; return 1; fi
    run install -m 0755 "$tmp" "$dest"
    rm -f "$tmp"
}

# A single gzipped binary, which is how a few projects ship.
_dt_fetch_gz() {
    local url=$1 dest=$2 tmp
    tmp=$(mktemp)
    if ! fetch "$url" -o "${tmp}.gz"; then rm -f "${tmp}.gz"; return 1; fi
    gunzip -cf "${tmp}.gz" >"$tmp" 2>/dev/null || { rm -f "$tmp" "${tmp}.gz"; return 1; }
    run install -m 0755 "$tmp" "$dest"
    rm -f "$tmp" "${tmp}.gz"
}

_dt_fetch_archive() {
    local url=$1 member=$2 dest=$3 tmp dir found
    tmp=$(mktemp); dir=$(mktemp -d)
    if ! fetch "$url" -o "$tmp"; then rm -rf "$tmp" "$dir"; return 1; fi

    if [[ $url == *.zip ]]; then
        have_cmd unzip || { log_warn "unzip is needed for ${dest##*/}"; rm -rf "$tmp" "$dir"; return 1; }
        unzip -qo "$tmp" -d "$dir" >/dev/null 2>&1 || { rm -rf "$tmp" "$dir"; return 1; }
    else
        tar -xzf "$tmp" -C "$dir" 2>/dev/null || { rm -rf "$tmp" "$dir"; return 1; }
    fi

    found=$(find "$dir" -type f -name "$member" -print -quit)
    [[ -n $found ]] || { log_warn "${member} not found in ${url##*/}"; rm -rf "$tmp" "$dir"; return 1; }
    run install -m 0755 "$found" "$dest"
    rm -rf "$tmp" "$dir"
}

_dt_verify_sha256() {
    local file=$1 expected=$2 actual
    [[ -n $expected ]] || return 0
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] || { log_error "checksum mismatch for ${file##*/}"; return 1; }
}

_dt_report_path() {
    case ":${PATH}:" in
        *":${DEVTOOLS_BIN_DIR}:"*) ;;
        *) log_warn "${DEVTOOLS_BIN_DIR} is not on this shell's PATH" ;;
    esac
    # A tool the service account cannot see is a tool that is not installed.
    # Reading its PATH needs runuser, which needs root — without it the answer
    # is "unknown", and reporting that as "wrong" sends the reader after a
    # problem that is not there.
    if [[ -n ${SERVICE_USER:-} ]] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
        local upath
        # shellcheck disable=SC2016  # $PATH must expand in the target shell
        upath=$(runuser -u "$SERVICE_USER" -- bash -lc 'printf %s "$PATH"' 2>/dev/null || printf '')
        if [[ -z $upath ]]; then
            log_info "cannot read ${SERVICE_USER}'s PATH without root; not checked"
            return 0
        fi
        case ":${upath}:" in
            *":${DEVTOOLS_BIN_DIR}:"*) log_ok "${SERVICE_USER} can reach ${DEVTOOLS_BIN_DIR}" ;;
            *) log_warn "${DEVTOOLS_BIN_DIR} is not on ${SERVICE_USER}'s PATH — the agent will not find these tools" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Recipes
# ---------------------------------------------------------------------------

_dt_install() {
    local tool=$1 pin=$2 arch x dest ver url sum tmp dir sums want a n

    # A preview downloads nothing. Each recipe costs a release lookup against a
    # 60-per-hour budget plus an archive, which would make a dry run both slow
    # and unrepeatable. Whether the recipes still resolve is checked by
    # tests/devtools-urls.sh, which is where a network dependency belongs.
    if [[ $DRY_RUN == true ]]; then
        log_info "[dry-run] install ${tool}${pin:+ (pinned ${pin})} -> ${DEVTOOLS_BIN_DIR}/${tool}"
        return 0
    fi

    arch=$(detect_arch)
    x=$([[ $arch == amd64 ]] && printf x86_64 || printf aarch64)
    dest="${DEVTOOLS_BIN_DIR}/${tool}"

    case $tool in

    # -- Kubernetes -------------------------------------------------------
    kubectl)
        ver=${pin:-$(fetch https://dl.k8s.io/release/stable.txt)}
        [[ -n $ver ]] || return 1
        url="https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl"
        sum=$(fetch "${url}.sha256" 2>/dev/null || printf '')
        tmp=$(mktemp)
        fetch "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
        _dt_verify_sha256 "$tmp" "$sum" || { rm -f "$tmp"; return 1; }
        run install -m 0755 "$tmp" "$dest"; rm -f "$tmp" ;;
    helm)
        ver=${pin:-$(_dt_github_latest helm/helm)}
        _dt_fetch_archive "https://get.helm.sh/helm-${ver}-linux-${arch}.tar.gz" helm "$dest" ;;
    kustomize)
        # The tag carries a path prefix ("kustomize/v5.8.1"); the asset does not.
        ver=${pin:-$(_dt_github_latest kubernetes-sigs/kustomize)}
        _dt_fetch_archive \
          "https://github.com/kubernetes-sigs/kustomize/releases/download/${ver}/kustomize_${ver#kustomize/}_linux_${arch}.tar.gz" \
          kustomize "$dest" ;;
    k9s)          _dt_gh derailed/k9s               "k9s_Linux_%a.tar.gz"                  k9s         "$pin" "$dest" ;;
    kubectx)      _dt_gh ahmetb/kubectx             "kubectx_%v_linux_%x.tar.gz"           kubectx     "$pin" "$dest" ;;
    kubens)       _dt_gh ahmetb/kubectx             "kubens_%v_linux_%x.tar.gz"            kubens      "$pin" "$dest" ;;
    stern)        _dt_gh stern/stern                "stern_%V_linux_%a.tar.gz"             stern       "$pin" "$dest" ;;
    helmfile)     _dt_gh helmfile/helmfile          "helmfile_%V_linux_%a.tar.gz"          helmfile    "$pin" "$dest" ;;
    kubeconform)  _dt_gh yannh/kubeconform          "kubeconform-linux-%a.tar.gz"          kubeconform "$pin" "$dest" ;;
    kind)         _dt_gh kubernetes-sigs/kind       "kind-linux-%a"                        ""          "$pin" "$dest" ;;

    # -- GitOps -----------------------------------------------------------
    argocd)       _dt_gh argoproj/argo-cd           "argocd-linux-%a"                      ""          "$pin" "$dest" ;;
    argo)         _dt_gh argoproj/argo-workflows    "argo-linux-%a.gz"                     ""          "$pin" "$dest" ;;
    flux)         _dt_gh fluxcd/flux2               "flux_%V_linux_%a.tar.gz"              flux        "$pin" "$dest" ;;
    kubeseal)     _dt_gh bitnami-labs/sealed-secrets "kubeseal-%V-linux-%a.tar.gz"         kubeseal    "$pin" "$dest" ;;
    velero)       _dt_gh vmware-tanzu/velero        "velero-%v-linux-%a.tar.gz"            velero      "$pin" "$dest" ;;

    # -- Infrastructure as code -------------------------------------------
    vault|terraform)
        # HashiCorp publish a checksum file next to every build.
        ver=${pin:-$(fetch "https://api.releases.hashicorp.com/v1/releases/${tool}/latest" 2>/dev/null \
                     | grep -oP '"version":\s*"\K[^"]+' | head -1)}
        [[ -n $ver ]] || return 1
        url="https://releases.hashicorp.com/${tool}/${ver}/${tool}_${ver}_linux_${arch}.zip"
        sums=$(fetch "https://releases.hashicorp.com/${tool}/${ver}/${tool}_${ver}_SHA256SUMS" 2>/dev/null || printf '')
        want=$(awk -v f="${tool}_${ver}_linux_${arch}.zip" '$2==f{print $1}' <<<"$sums")
        tmp=$(mktemp)
        fetch "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
        _dt_verify_sha256 "$tmp" "$want" || { rm -f "$tmp"; return 1; }
        dir=$(mktemp -d)
        unzip -qo "$tmp" -d "$dir" && run install -m 0755 "${dir}/${tool}" "$dest"
        rm -rf "$tmp" "$dir" ;;
    tofu)            _dt_gh opentofu/opentofu       "tofu_%V_linux_%a.tar.gz"              tofu        "$pin" "$dest" ;;
    terragrunt)      _dt_gh gruntwork-io/terragrunt "terragrunt_linux_%a"                  ""          "$pin" "$dest" ;;
    tflint)          _dt_gh terraform-linters/tflint "tflint_linux_%a.zip"                 tflint      "$pin" "$dest" ;;
    terraform-docs)  _dt_gh terraform-docs/terraform-docs "terraform-docs-%v-linux-%a.tar.gz" terraform-docs "$pin" "$dest" ;;

    # -- Secrets ----------------------------------------------------------
    sops)         _dt_gh getsops/sops               "sops-%v.linux.%a"                     ""          "$pin" "$dest" ;;
    age)          _dt_gh FiloSottile/age            "age-%v-linux-%a.tar.gz"               age         "$pin" "$dest" ;;

    # -- Supply chain and security ----------------------------------------
    trivy)
        a=$arch; [[ $a == amd64 ]] && a=64bit || a=ARM64
        _dt_gh aquasecurity/trivy "trivy_%V_Linux-${a}.tar.gz"                             trivy       "$pin" "$dest" ;;
    cosign)       _dt_gh sigstore/cosign            "cosign-linux-%a"                      ""          "$pin" "$dest" ;;
    syft)         _dt_gh anchore/syft               "syft_%V_linux_%a.tar.gz"              syft        "$pin" "$dest" ;;
    grype)        _dt_gh anchore/grype              "grype_%V_linux_%a.tar.gz"             grype       "$pin" "$dest" ;;
    hadolint)     _dt_gh hadolint/hadolint          "hadolint-Linux-%x"                    ""          "$pin" "$dest" ;;

    # -- Containers and registries ----------------------------------------
    crane)        _dt_gh google/go-containerregistry "go-containerregistry_Linux_%x.tar.gz" crane      "$pin" "$dest" ;;
    dive)         _dt_gh wagoodman/dive             "dive_%V_linux_%a.tar.gz"              dive        "$pin" "$dest" ;;

    # -- Data: JSON, YAML and friends -------------------------------------
    yq)           _dt_gh mikefarah/yq               "yq_linux_%a"                          ""          "$pin" "$dest" ;;
    dasel)        _dt_gh TomWright/dasel            "dasel_linux_%a"                       ""          "$pin" "$dest" ;;
    gojq)         _dt_gh itchyny/gojq               "gojq_%v_linux_%a.tar.gz"              gojq        "$pin" "$dest" ;;
    jless)        _dt_gh PaulJuliusMartinez/jless   "jless-%v-%x-unknown-linux-gnu.zip"    jless       "$pin" "$dest" ;;
    jsonnet)      _dt_gh google/go-jsonnet          "go-jsonnet_%V_linux_%a.tar.gz"        jsonnet     "$pin" "$dest" ;;

    # -- Git and everyday development -------------------------------------
    gh)           _dt_gh cli/cli                    "gh_%V_linux_%a.tar.gz"                gh          "$pin" "$dest" ;;
    lazygit)      _dt_gh jesseduffield/lazygit      "lazygit_%V_Linux_%x.tar.gz"           lazygit     "$pin" "$dest" ;;
    delta)        _dt_gh dandavison/delta           "delta-%v-%x-unknown-linux-gnu.tar.gz" delta       "$pin" "$dest" ;;
    just)         _dt_gh casey/just                 "just-%v-%x-unknown-linux-musl.tar.gz" just        "$pin" "$dest" ;;
    task)         _dt_gh go-task/task               "task_linux_%a.tar.gz"                 task        "$pin" "$dest" ;;
    k6)           _dt_gh grafana/k6                 "k6-%v-linux-%a.tar.gz"                k6          "$pin" "$dest" ;;

    # -- Media -------------------------------------------------------------
    yt-dlp)
        # Video platforms serve a bot interstitial to plain fetches from
        # datacentre addresses, so transcript extraction needs a real downloader
        # — optionally with a signed-in cookie jar.
        n=yt-dlp_linux; [[ $arch == arm64 ]] && n=yt-dlp_linux_aarch64
        _dt_gh yt-dlp/yt-dlp "$n" "" "$pin" "$dest" ;;

    *)
        log_error "no recipe for '${tool}'"
        log_error "  add a line in src/58-devtools.sh, or remove it from DEVTOOLS_INSTALL"
        return 1 ;;
    esac
}

# The bots, the assistant MCP servers and the mail relay — one image, because the MCP
# servers run as child processes of a gateway and the relay shares its Python.
#
# It builds FROM the vendor's own image rather than re-deriving it. That image already
# compiles SQLite from source (the distribution's release carries a write-ahead-log
# corruption bug), bakes the messaging extras so an adapter does not pip-install itself
# on first connect into a filesystem that will not survive the pod, and creates the
# account the agent expects: uid 10000, home /opt/data.
ARG HERMES_REF=v2026.8.31
FROM ghcr.io/nousresearch/hermes-agent:${HERMES_REF}

USER root

# The four patches this repository carries into vendor source. On the VM they are
# applied by the hermes module on every run; here they are applied once, at build, and
# a vendor bump that moves an anchor fails the BUILD instead of failing a run on a
# machine that has already taken the new code.
COPY libs/60-hermes.sh /tmp/patches/
COPY deploy/images/apply-patches.sh /tmp/patches/
RUN /tmp/patches/apply-patches.sh && rm -rf /tmp/patches

# The assistant servers and their two document libraries. Pinned, like everything else.
ARG PYPDF_VERSION=6.17.0
ARG DOCX_VERSION=1.2.0
COPY bot/mcp/ /usr/local/lib/hermes-assistant/
RUN python3 -m venv /usr/local/lib/hermes-assistant/venv \
 && /usr/local/lib/hermes-assistant/venv/bin/pip install --no-cache-dir \
      "pypdf==${PYPDF_VERSION}" "python-docx==${DOCX_VERSION}"

# The personas and the help pages the init container renders into a profile.
COPY bot/roles/ /usr/local/share/hermes/roles/
COPY bot/help/ /usr/local/share/hermes/help/
COPY bot/help.md.tpl /usr/local/share/hermes/

# The entry points the workloads name. seed-profile is the init container; the other
# three are the loopback services of the VM, each now its own Deployment.
COPY deploy/images/bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/seed-profile /usr/local/bin/mailproxy \
                /usr/local/bin/balance-proxy /usr/local/bin/dashboard

USER 10000

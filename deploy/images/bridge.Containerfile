# The bridge: an OpenAI-compatible endpoint backed by a subscription CLI.
#
# The CLI itself is NOT in this image. It is a closed-source binary of about 200 MB
# that authenticates against a subscription, and baking it into an image would be
# redistributing it. A maintenance job installs it once onto the CLI volume and signs
# in there; this image carries only the bridge and the tools server, and the binary is
# found on $PATH from that volume at runtime.
#
# Debian rather than Alpine: the CLI is dynamically linked against glibc.
FROM python:3.13-slim-trixie

RUN useradd -u 10000 -m -d /opt/cli hermes

COPY bot/agy-shim/agy_shim.py /usr/local/lib/hermes-provisioner/
COPY bot/agy-shim/tools_mcp.py /usr/local/lib/hermes-provisioner/
COPY bot/api-proxy/balance_proxy.py /usr/local/lib/hermes-provisioner/
RUN chmod 0755 /usr/local/lib/hermes-provisioner/*.py

ENV PATH=/opt/cli/.local/bin:/usr/local/bin:/usr/bin:/bin
ENV AGY_SHIM_HOST=0.0.0.0
# 0.0.0.0 is refused by the installer's validator on a host, and rightly: the bridge
# authenticates nothing. In a pod there is no loopback to bind to, and what replaces
# the kernel's boundary is the NetworkPolicy the chart renders beside this workload.

USER 10000
WORKDIR /opt/cli
ENTRYPOINT ["python3", "/usr/local/lib/hermes-provisioner/agy_shim.py"]

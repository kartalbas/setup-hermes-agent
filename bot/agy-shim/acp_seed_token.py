#!/usr/bin/env python3
"""Derive the ACP server's OAuth token from the agy CLI's sign-in.

Used only by the installer when AGY_SHIM_BACKEND=acp and no ACP token exists
yet (libs/35-agy-shim.sh). The ACP server and the CLI ship the same OAuth
client, and the CLI's id_token names that client as its audience — so the
refresh token the CLI holds is one this client issued, and the server, loading
a google-auth authorized-user file, may use it. The installed-app client
secret is shipped inside the server binary as _DEFAULT_CLIENT_SECRET.

This reuses the ONE sign-in the print backend already needs; it adds no second
interactive step. It is a shortcut, and it breaks if Google rotates the client
secret or the refresh token is revoked — the fallback is the server's own
interactive OAuth flow (docs/research/agy-cli.md). Writes 0600.

    acp_seed_token.py <cli-token-file> <acp-server-binary> <out-token-file>

Standard library only. Run AS THE SERVICE ACCOUNT, so the file it writes and
the home it writes into belong to the account the bridge runs as.
"""
from __future__ import annotations

import base64
import json
import os
import re
import stat
import subprocess
import sys

# The scopes the ACP server requests (its _DEFAULT_SCOPES), read from the
# binary docstring on 2026-09-13. Kept explicit so a scope change is a visible
# edit, not a silent drift.
SCOPES = [
    "https://www.googleapis.com/auth/aicode",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
]


def client_id_from(cli_token: dict) -> str:
    """The OAuth client the CLI's token belongs to: the id_token's audience."""
    payload = cli_token["id_token"].split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))["aud"]


def client_secret_from(server_binary: str) -> str:
    out = subprocess.run(["strings", server_binary], capture_output=True, text=True).stdout
    m = re.search(r'_DEFAULT_CLIENT_SECRET = "(GOCSPX-[A-Za-z0-9_-]+)"', out)
    if not m:
        sys.exit("could not read the client secret from the ACP server binary")
    return m.group(1)


def main() -> int:
    cli_path, server, out = sys.argv[1:4]
    src = json.load(open(cli_path, encoding="utf-8"))
    refresh = (src.get("token") or {}).get("refresh_token")
    if not refresh:
        sys.exit("the CLI token file carries no refresh_token")

    token = {
        "type": "authorized_user",
        "client_id": client_id_from(src),
        "client_secret": client_secret_from(server),
        "refresh_token": refresh,
        "scopes": SCOPES,
    }
    os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(token, f, indent=1)
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)   # 0600; no access token, so first use refreshes
    os.replace(tmp, out)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

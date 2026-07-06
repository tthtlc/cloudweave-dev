#!/usr/bin/env python3
"""
dex_bootstrap.py
================

Render Dex config from template and write generated/dex.env for libcloud REST + scripts.

Users live in LLDAP (../lldap). Dex authenticates against LLDAP over an LDAP
connector (no staticPasswords / enablePasswordDB). Dex remains the stable OIDC
issuer; the user directory is externalized so swapping LLDAP for another
upstream IdP later only changes the connector, not libcloud-rest's client_id.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

logging.basicConfig(
    level=os.environ.get("DEX_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("dex-bootstrap")

ROOT = Path(__file__).resolve().parent
# Dex config + generated env live in the sibling ../dex project (self-contained
# standalone compose). Override via DEX_DIR / DEX_OUTPUT_DIR for non-default layouts.
DEX_DIR = Path(os.environ.get("DEX_DIR", ROOT.parent / "dex"))
TEMPLATE = DEX_DIR / "config.template.yaml"
OUTPUT_CONFIG = DEX_DIR / "config.yaml"
GENERATED_DIR = Path(os.environ.get("DEX_OUTPUT_DIR", DEX_DIR / "generated"))


def wait_for_dex(base_url: str, timeout: float = 120.0) -> None:
    deadline = time.time() + timeout
    url = base_url.rstrip("/") + "/dex/.well-known/openid-configuration"
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                if resp.status == 200:
                    log.info("Dex OIDC discovery available at %s", url)
                    return
        except Exception:
            time.sleep(2)
    raise RuntimeError(f"Timed out waiting for Dex at {url}")


def render_config(
    *,
    issuer: str,
    client_secret: str,
    lldap_bind_dn: str,
    lldap_bind_pw: str,
    lldap_base_dn: str,
) -> None:
    if not TEMPLATE.exists():
        raise FileNotFoundError(TEMPLATE)
    text = TEMPLATE.read_text(encoding="utf-8")
    rendered = (
        text.replace("__DEX_ISSUER__", issuer)
        .replace("__CLIENT_SECRET__", client_secret)
        .replace("__LLDAP_BIND_DN__", lldap_bind_dn)
        .replace("__LLDAP_BIND_PW__", lldap_bind_pw)
        .replace("__LLDAP_BASE_DN__", lldap_base_dn)
    )
    OUTPUT_CONFIG.write_text(rendered, encoding="utf-8")
    log.info("Wrote %s", OUTPUT_CONFIG)


def _gen_password() -> str:
    import secrets as _s
    return "SA-" + _s.token_urlsafe(18)


def write_env(
    *,
    public_url: str,
    issuer: str,
    client_id: str,
    client_secret: str,
) -> Path:
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    # `public_url` is host-reachable (http://localhost:5556) — used for the
    # browser flow, token endpoint, and host-side JWKS fetch. `issuer` is the
    # canonical issuer string Dex puts in the token `iss` claim
    # (http://dex:5556/dex, the in-container DNS URL) — used for `iss`
    # validation by verify_superadmin_jwt.py and the libcloud REST API, and for
    # OpenFGA's OIDC authn (which fetches JWKS from `<issuer>/keys` in-container).
    # See authorization.md §15.3 / rest_api_security.md.
    env_path = GENERATED_DIR / "dex.env"

    # Per-user passwords. Each is taken from the matching LIBCLOUD_PASSWORD_*
    # env var if set; otherwise a fresh random password is generated and
    # written back so setup.sh can use it to create the LLDAP user. The
    # superadmin password is also persisted so the gating helper can log in.
    users = [
        ("superadmin", "LIBCLOUD_SUPERADMIN_PASSWORD"),
        ("aws-owner", "LIBCLOUD_PASSWORD_AWS_OWNER"),
        ("aws-admin", "LIBCLOUD_PASSWORD_AWS_ADMIN"),
        ("aws-viewer", "LIBCLOUD_PASSWORD_AWS_VIEWER"),
        ("ntnx-owner", "LIBCLOUD_PASSWORD_NTNX_OWNER"),
        ("ntnx-admin", "LIBCLOUD_PASSWORD_NTNX_ADMIN"),
        ("ntnx-viewer", "LIBCLOUD_PASSWORD_NTNX_VIEWER"),
        ("cloud-denied", "LIBCLOUD_PASSWORD_CLOUD_DENIED"),
    ]
    pw_lines = []
    for uid, env_key in users:
        pw = os.environ.get(env_key, "").strip()
        if not pw:
            pw = _gen_password()
            os.environ[env_key] = pw  # propagate to setup.sh via /proc? no — caller reads file
        pw_lines.append(f"LIBCLOUD_USER_{uid.upper().replace('-', '_')}={uid}")
        pw_lines.append(f"{env_key}={pw}")

    host_base = public_url.rstrip("/") + "/dex"
    lines = [
        f"DEX_URL={public_url.rstrip('/')}",
        f"DEX_ISSUER_URL={issuer}",
        # JWKS + discovery use the HOST-reachable URL (host scripts cannot
        # resolve the in-container `dex` DNS name). The issuer string above is
        # the canonical in-container value used for `iss` validation.
        f"DEX_JWKS_URL={host_base}/keys",
        f"DEX_OIDC_DISCOVERY={host_base}/.well-known/openid-configuration",
        f"LIBCLOUD_OIDC_CLIENT_ID={client_id}",
        f"LIBCLOUD_OIDC_CLIENT_SECRET={client_secret}",
        f"OIDC_ISSUER_URL={issuer}",
        f"OIDC_JWKS_URL={issuer}/keys",
        f"OIDC_AUDIENCE={client_id}",
        "",
        "# Users live in LLDAP (../lldap); Dex authenticates against LLDAP over",
        "# LDAP. These password entries are consumed by the host provisioning",
        "# scripts (idp_login.py) and the superadmin gating helper. Manage users",
        "# in LLDAP, not here. superadmin is the bootstrap identity that gates",
        "# Vault seeding, OpenFGA policy changes, and LLDAP user management.",
    ]
    lines.extend(pw_lines)
    env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    log.info("Wrote %s", env_path)
    return env_path


def main() -> int:
    public_url = os.environ.get("DEX_PUBLIC_URL", "http://localhost:5556").rstrip("/")
    internal_url = os.environ.get("DEX_URL", "http://dex:5556").rstrip("/")
    client_id = os.environ.get("LIBCLOUD_OIDC_CLIENT_ID", "libcloud-rest")
    client_secret = os.environ.get("LIBCLOUD_OIDC_CLIENT_SECRET") or secrets.token_urlsafe(32)

    issuer_public = public_url + "/dex"
    # Canonical issuer = the in-container DNS URL (http://dex:5556/dex). Dex
    # puts this in the token `iss` claim; OpenFGA (in-container) fetches JWKS
    # from `<issuer>/keys`. Host-side JWKS/discovery use public_url (see
    # write_env). Override via DEX_ISSUER if you need a different canonical host.
    issuer = os.environ.get("DEX_ISSUER", internal_url.rstrip("/") + "/dex").rstrip("/")
    # LLDAP bind credentials (users live in LLDAP, Dex authenticates via LDAP).
    # Defaults assume dc=libcloud,dc=local; override via env (setup.sh sources
    # ../lldap/.env and exports these).
    lldap_base_dn = os.environ.get("LLDAP_BASE_DN", "dc=libcloud,dc=local")
    lldap_admin_uid = os.environ.get("LLDAP_ADMIN_USER", "admin")
    lldap_bind_dn = os.environ.get(
        "LLDAP_BIND_DN", f"uid={lldap_admin_uid},ou=people,{lldap_base_dn}"
    )
    lldap_bind_pw = os.environ.get("LLDAP_BIND_PW", "")
    render_config(
        issuer=issuer,
        client_secret=client_secret,
        lldap_bind_dn=lldap_bind_dn,
        lldap_bind_pw=lldap_bind_pw,
        lldap_base_dn=lldap_base_dn,
    )
    env_path = write_env(
        public_url=public_url,
        issuer=issuer,
        client_id=client_id,
        client_secret=client_secret,
    )

    # When run after Dex container starts, verify discovery endpoint.
    if os.environ.get("DEX_WAIT", "1") == "1":
        try:
            wait_for_dex(public_url)
        except RuntimeError as exc:
            log.warning("%s (config still written)", exc)

    print(
        json.dumps(
            {
                "dex_env": str(env_path),
                "issuer": issuer + "/",
                "client_id": client_id,
                "internal_url": internal_url,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

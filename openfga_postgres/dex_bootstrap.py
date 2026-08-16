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
    # Try the provided URL first, then fall back to localhost (port 5556 is
    # always published on the host). In air-gapped deployments the public
    # hostname may not resolve, but localhost always works.
    urls_to_try = [base_url.rstrip("/") + "/dex/.well-known/openid-configuration"]
    if "localhost" not in urls_to_try[0] and "127.0.0.1" not in urls_to_try[0]:
        urls_to_try.append("http://localhost:5556/dex/.well-known/openid-configuration")
    while time.time() < deadline:
        for url in urls_to_try:
            try:
                with urllib.request.urlopen(url, timeout=5) as resp:
                    if resp.status == 200:
                        log.info("Dex OIDC discovery available at %s", url)
                        return
            except Exception:
                continue
        time.sleep(2)
    raise RuntimeError(f"Timed out waiting for Dex at {urls_to_try}")


def render_config(
    *,
    issuer: str,
    client_secret: str,
    lldap_bind_dn: str,
    lldap_bind_pw: str,
    lldap_base_dn: str,
    portal_client_block: str,
    extra_connectors_block: str,
    visualizer_public_callback: str = "",
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
        .replace("__PORTAL_CLIENT__", portal_client_block)
        .replace("__EXTRA_CONNECTORS__", extra_connectors_block)
        .replace("__VISUALIZER_PUBLIC_CALLBACK__", visualizer_public_callback)
    )
    OUTPUT_CONFIG.write_text(rendered, encoding="utf-8")
    log.info("Wrote %s", OUTPUT_CONFIG)


def _portal_client_block(
    *,
    portal_client_id: str,
    portal_client_secret: str,
    portal_redirect_uri: str,
    public_hostname: str = "",
) -> str:
    # Rendered as a YAML list item under the existing staticClients list.
    # Indented to match the libcloud-rest entry (2 spaces under staticClients).
    if not portal_redirect_uri and not public_hostname:
        return ""
    if not portal_client_id:
        portal_client_id = "libcloud-portal"
    # Always include localhost for local dev, plus the public-hostname redirect
    # (derived from PUBLIC_HOSTNAME env var) for remote access. Dedup in case
    # the single portal_redirect_uri already matches one.
    redirects = set()
    if portal_redirect_uri:
        redirects.add(portal_redirect_uri)
    redirects.add("http://localhost:3000/auth/callback")
    if public_hostname:
        redirects.add(f"http://{public_hostname}:3000/auth/callback")
    redirect_yaml = "\n".join(f"      - {u}" for u in sorted(redirects))
    return (
        f"  - id: {portal_client_id}\n"
        f"    name: libcloud Role Portal\n"
        f"    secret: {portal_client_secret}\n"
        f"    redirectURIs:\n"
        f"{redirect_yaml}\n"
    )


def _extra_connectors_block(
    *,
    issuer: str,
    google_client_id: str,
    google_client_secret: str,
    github_client_id: str,
    github_client_secret: str,
) -> str:
    # Appended after the ldap connector inside the `connectors:` list.
    # Dex's google/github connectors validate that the configured `redirectURI`
    # equals `{issuer}/callback` (empty fails validation), and they send that
    # exact URL to the upstream IdP — so it MUST be the browser-public callback
    # the user registered in their Google/GitHub OAuth app. With a public issuer
    # (see main()), `{issuer}/callback` is browser-reachable.
    callback = issuer.rstrip("/") + "/callback"
    parts = []
    if google_client_id and google_client_secret:
        parts.append(
            "  - type: google\n"
            "    id: google\n"
            "    name: Google\n"
            "    config:\n"
            f"      clientID: {google_client_id}\n"
            f"      clientSecret: {google_client_secret}\n"
            f"      redirectURI: {callback}\n"
            "      # TODO: restrict to your org domain(s) via hostedDomains.\n"
        )
    if github_client_id and github_client_secret:
        parts.append(
            "  - type: github\n"
            "    id: github\n"
            "    name: GitHub\n"
            "    config:\n"
            f"      clientID: {github_client_id}\n"
            f"      clientSecret: {github_client_secret}\n"
            f"      redirectURI: {callback}\n"
            "      # TODO: restrict via orgs/teams if you want group claims.\n"
        )
    return "".join(parts)


def _gen_password() -> str:
    import secrets as _s
    return "SA-" + _s.token_urlsafe(18)


def write_env(
    *,
    public_url: str,
    issuer: str,
    client_id: str,
    client_secret: str,
    portal_client_id: str = "",
    portal_client_secret: str = "",
    portal_redirect_uri: str = "",
    public_hostname: str = "",
    google_client_id: str = "",
    google_client_secret: str = "",
    github_client_id: str = "",
    github_client_secret: str = "",
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
    # If a password is not set in the environment, try to reuse the value from
    # an existing dex.env (idempotent re-runs). Only generate a fresh password
    # when neither source provides one (first boot). This prevents password
    # drift between dex.env and LLDAP across re-runs of dex_bootstrap.py.
    _existing_env = {}
    if env_path.exists():
        for _line in env_path.read_text(encoding="utf-8").splitlines():
            if "=" in _line and not _line.startswith("#"):
                _k, _, _v = _line.partition("=")
                _existing_env[_k.strip()] = _v.strip()

    pw_lines = []
    for uid, env_key in users:
        pw = os.environ.get(env_key, "").strip()
        if not pw and env_key in _existing_env:
            pw = _existing_env[env_key]
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
        # now the public URL (so federated connector callbacks are
        # browser-reachable); in-container consumers override OIDC_JWKS_URL to
        # http://dex:5556/dex/keys in their own compose files for fast JWKS.
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
    # Optional phase-2 federation + portal client (consumed by ../server portal
    # backend). Only emitted when the corresponding env vars were set so the
    # libcloud REST API / OpenFGA / host scripts are unaffected otherwise.
    if portal_redirect_uri or public_hostname:
        lines.append("")
        lines.append("# Role portal (../server) OAuth client + federation.")
        lines.append(f"DEX_PORTAL_CLIENT_ID={portal_client_id or 'libcloud-portal'}")
        lines.append(f"DEX_PORTAL_CLIENT_SECRET={portal_client_secret}")
        lines.append(f"DEX_PORTAL_REDIRECT_URI={portal_redirect_uri or f'http://{public_hostname}:3000/auth/callback'}")
    if google_client_id:
        lines.append(f"DEX_GOOGLE_CLIENT_ID={google_client_id}")
        # Persist the secret too — otherwise a re-run of dex_bootstrap.py (which
        # reads DEX_GOOGLE_CLIENT_SECRET from the environment, normally sourced
        # from this very file) would drop the google connector on the next render.
        if google_client_secret:
            lines.append(f"DEX_GOOGLE_CLIENT_SECRET={google_client_secret}")
    if github_client_id:
        lines.append(f"DEX_GITHUB_CLIENT_ID={github_client_id}")
        if github_client_secret:
            lines.append(f"DEX_GITHUB_CLIENT_SECRET={github_client_secret}")
    env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    log.info("Wrote %s", env_path)
    return env_path


def main() -> int:
    public_url = os.environ.get("DEX_PUBLIC_URL", "http://localhost:5556").rstrip("/")
    internal_url = os.environ.get("DEX_INTERNAL_URL", "http://dex:5556").rstrip("/")
    client_id = os.environ.get("LIBCLOUD_OIDC_CLIENT_ID", "libcloud-rest")
    client_secret = os.environ.get("LIBCLOUD_OIDC_CLIENT_SECRET") or secrets.token_urlsafe(32)

    # The canonical issuer (Dex's `iss` claim in JWTs) defaults to the
    # INTERNAL (in-container) URL http://dex:5556/dex so all Docker services
    # (OpenFGA, identity-service, libcloud-rest) can reach Dex for JWKS fetch
    # without needing public DNS. The browser-facing authorize URL is built
    # separately from DEX_PUBLIC_URL (see identity_service's dex_base_url).
    # In air-gapped deployments the internal URL always works; for federated
    # connectors (Google/GitHub) the issuer must be browser-reachable — set
    # DEX_ISSUER=http://<public-host>:5556/dex explicitly in that case.
    # Override via DEX_ISSUER env var for non-standard layouts.
    issuer_default = internal_url + "/dex"
    issuer = os.environ.get("DEX_ISSUER", issuer_default).rstrip("/")
    # LLDAP bind credentials (users live in LLDAP, Dex authenticates via LDAP).
    # Defaults assume dc=libcloud,dc=local; override via env (setup.sh sources
    # ../lldap/.env and exports these).
    lldap_base_dn = os.environ.get("LLDAP_BASE_DN", "dc=libcloud,dc=local")
    lldap_admin_uid = os.environ.get("LLDAP_ADMIN_USER", "admin")
    lldap_bind_dn = os.environ.get(
        "LLDAP_BIND_DN", f"uid={lldap_admin_uid},ou=people,{lldap_base_dn}"
    )
    lldap_bind_pw = os.environ.get("LLDAP_BIND_PW", "")

    # Optional phase-2 federation + portal client (../server). All empty by
    # default so behavior is identical to the LLDAP-only stack when unset.
    # DEX_DISABLE_FEDERATION=1 forces Google/GitHub connectors off regardless
    # of credential values — use in air-gapped (offline) deployments where Dex
    # cannot reach accounts.google.com / github.com at startup.
    disable_federation = os.environ.get("DEX_DISABLE_FEDERATION", "").strip() in ("1", "true", "yes")
    if disable_federation:
        google_client_id = ""
        google_client_secret = ""
        github_client_id = ""
        github_client_secret = ""
        log.info("DEX_DISABLE_FEDERATION=1 — Google/GitHub connectors disabled (air-gapped mode)")
    else:
        google_client_id = os.environ.get("DEX_GOOGLE_CLIENT_ID", "").strip()
        google_client_secret = os.environ.get("DEX_GOOGLE_CLIENT_SECRET", "").strip()
        github_client_id = os.environ.get("DEX_GITHUB_CLIENT_ID", "").strip()
        github_client_secret = os.environ.get("DEX_GITHUB_CLIENT_SECRET", "").strip()
    portal_client_id = os.environ.get("DEX_PORTAL_CLIENT_ID", "libcloud-portal").strip()
    portal_client_secret = os.environ.get("DEX_PORTAL_CLIENT_SECRET", "").strip()
    portal_redirect_uri = os.environ.get("DEX_PORTAL_REDIRECT_URI", "").strip()
    public_hostname = os.environ.get("PUBLIC_HOSTNAME", "").strip()
    # Generate a portal client secret once if a portal client is requested but
    # no secret was supplied, so render_config and write_env emit the same value.
    if (portal_redirect_uri or public_hostname) and not portal_client_secret:
        portal_client_secret = secrets.token_urlsafe(32)

    portal_client_block = _portal_client_block(
        portal_client_id=portal_client_id,
        portal_client_secret=portal_client_secret,
        portal_redirect_uri=portal_redirect_uri,
        public_hostname=public_hostname,
    )
    extra_connectors_block = _extra_connectors_block(
        issuer=issuer,
        google_client_id=google_client_id,
        google_client_secret=google_client_secret,
        github_client_id=github_client_id,
        github_client_secret=github_client_secret,
    )
    # OpenFGA visualizer (port 5050) uses the libcloud-rest OAuth client.
    # Include the public-hostname callback only when PUBLIC_HOSTNAME is set.
    visualizer_public_callback = ""
    if public_hostname:
        visualizer_public_callback = f"- http://{public_hostname}:5050/callback"

    render_config(
        issuer=issuer,
        client_secret=client_secret,
        lldap_bind_dn=lldap_bind_dn,
        lldap_bind_pw=lldap_bind_pw,
        lldap_base_dn=lldap_base_dn,
        portal_client_block=portal_client_block,
        extra_connectors_block=extra_connectors_block,
        visualizer_public_callback=visualizer_public_callback,
    )
    env_path = write_env(
        public_url=public_url,
        issuer=issuer,
        client_id=client_id,
        client_secret=client_secret,
        portal_client_id=portal_client_id,
        portal_client_secret=portal_client_secret,
        portal_redirect_uri=portal_redirect_uri,
        public_hostname=public_hostname,
        google_client_id=google_client_id,
        google_client_secret=google_client_secret,
        github_client_id=github_client_id,
        github_client_secret=github_client_secret,
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

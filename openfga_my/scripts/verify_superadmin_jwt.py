#!/usr/bin/env python3
"""Verify a Dex-issued JWT belongs to the bootstrap `superadmin` identity.

Used by the privileged bootstraps (vault_bootstrap.py, openfga_bootstrap.py)
and by setup.sh before LLDAP user CRUD to enforce: without a successful
superadmin login, none of those operations are possible.

Checks:
  1. SUPERADMIN_JWT env var is present.
  2. JWT signature validates against the Dex JWKS (RS256).
  3. iss matches the Dex issuer, aud contains the libcloud-rest client id.
  4. exp is in the future.
  5. The subject is superadmin — by email (superadmin@libcloud.local) or by
     the LLDAP uid encoded in the Dex LDAP `sub`.

Exit 0 if valid, 1 otherwise. Prints a short reason to stderr.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.request

SUPERADMIN_UID = os.environ.get("SUPERADMIN_UID", "superadmin")
SUPERADMIN_EMAIL = os.environ.get("SUPERADMIN_EMAIL", f"{SUPERADMIN_UID}@libcloud.local")
CLIENT_ID = os.environ.get("LIBCLOUD_OIDC_CLIENT_ID", "libcloud-rest")
DEX_URL = os.environ.get("DEX_URL", "http://localhost:5556").rstrip("/")
# Dex configures the issuer without a trailing slash (e.g.
# http://localhost:5556/dex); the JWT `iss` claim mirrors that exactly. Do not
# force a trailing slash here, or the iss comparison will always fail.
ISSUER = os.environ.get("DEX_ISSUER_URL", f"{DEX_URL}/dex").rstrip("/")


def _fail(msg: str) -> int:
    print(f"superadmin JWT verification failed: {msg}", file=sys.stderr)
    return 1


def _b64url(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def _fetch_jwks(jwks_url: str) -> dict:
    with urllib.request.urlopen(jwks_url, timeout=10) as resp:
        return json.loads(resp.read().decode() or "{}")


def _verify_rs256(header: dict, payload_seg: str, sig_seg: str, jwks: dict) -> bool:
    try:
        import cryptography.hazmat.primitives.asymmetric.padding as padding
        import cryptography.hazmat.primitives.hashes as hashes
        from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
        from cryptography.exceptions import InvalidSignature
    except ImportError:
        print("cryptography package required for JWT signature verification", file=sys.stderr)
        return False

    kid = header.get("kid")
    key = next((k for k in jwks.get("keys", []) if k.get("kid") == kid), None)
    if key is None:
        return False
    n = int.from_bytes(_b64url(key["n"]), "big")
    e = int.from_bytes(_b64url(key["e"]), "big")
    pub = RSAPublicNumbers(e, n).public_key()
    # JWT signing input is "<base64url header>.<base64url payload>" — the full
    # payload_seg passed in. The earlier `rsplit(".", 1)[0]` incorrectly stripped
    # the payload, leaving only the header, so every signature "verified" as
    # invalid.
    signing_input = payload_seg.encode()
    try:
        pub.verify(_b64url(sig_seg), signing_input, padding.PKCS1v15(), hashes.SHA256())
        return True
    except InvalidSignature:
        return False


def main() -> int:
    tok = os.environ.get("SUPERADMIN_JWT", "").strip()
    if not tok:
        return _fail("SUPERADMIN_JWT env var is not set")
    parts = tok.split(".")
    if len(parts) != 3:
        return _fail("not a JWT")
    header = json.loads(_b64url(parts[0]))
    payload = json.loads(_b64url(parts[1]))

    if header.get("alg") != "RS256":
        return _fail(f"unsupported alg {header.get('alg')}")
    try:
        jwks = _fetch_jwks(os.environ.get("DEX_JWKS_URL", f"{ISSUER.rstrip('/')}/keys"))
    except Exception as exc:
        return _fail(f"cannot fetch JWKS: {exc}")
    if not _verify_rs256(header, f"{parts[0]}.{parts[1]}", parts[2], jwks):
        return _fail("signature invalid")

    if payload.get("iss", "").rstrip("/") != ISSUER:
        return _fail(f"iss mismatch: {payload.get('iss')} != {ISSUER}")
    aud = payload.get("aud")
    if not (aud == CLIENT_ID or (isinstance(aud, list) and CLIENT_ID in aud)):
        return _fail(f"aud mismatch: {aud}")
    exp = payload.get("exp")
    if not exp or int(time.time()) >= int(exp):
        return _fail("token expired")

    sub = payload.get("sub", "")
    email = payload.get("email", "")
    if sub != SUPERADMIN_UID and email != SUPERADMIN_EMAIL:
        return _fail(f"subject is not superadmin (sub={sub}, email={email})")
    print(f"superadmin JWT verified (sub={sub}, email={email})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

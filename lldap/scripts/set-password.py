#!/usr/bin/env python3
"""Set (reset) an LLDAP user's password over LDAP via the PasswordModify
extended operation, binding as admin. No docker exec needed.

Env vars:
  LLDAP_LDAP_URL   e.g. ldap://localhost:3890  (default ldap://localhost:3890)
  LLDAP_BASE_DN    e.g. dc=libcloud,dc=local
  LLDAP_ADMIN_USER admin bind DN, defaults to uid=admin,ou=people,<base>
  LLDAP_ADMIN_PASS admin password (required)

Usage: set-password.py <username> <new_password>
"""
import os
import sys

import ldap3


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    username, new_password = sys.argv[1], sys.argv[2]

    base_dn = os.environ.get("LLDAP_BASE_DN", "dc=libcloud,dc=local")
    ldap_url = os.environ.get("LLDAP_LDAP_URL", "ldap://localhost:3890")
    admin_uid = os.environ.get("LLDAP_ADMIN_USER", "admin")
    admin_user = f"uid={admin_uid},ou=people,{base_dn}"
    admin_pass = os.environ.get("LLDAP_ADMIN_PASS")
    if not admin_pass:
        print("LLDAP_ADMIN_PASS is required", file=sys.stderr)
        return 2

    user_dn = f"uid={username},ou=people,{base_dn}"
    server = ldap3.Server(ldap_url)
    conn = ldap3.Connection(
        server, user=admin_user, password=admin_pass, auto_bind=True
    )
    try:
        conn.extend.standard.modify_password(user=user_dn, new_password=new_password)
        print(f"Password set for {username} ({user_dn})")
    finally:
        conn.unbind()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

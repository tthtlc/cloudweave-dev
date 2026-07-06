#!/usr/bin/env python3
"""Verify the LLDAP directory over LDAP: bind as admin, list users, and show
the six managed fields for each. Optionally bind as a given user to confirm
their password works.

Env vars:
  LLDAP_LDAP_URL   default ldap://localhost:3890
  LLDAP_BASE_DN    default dc=libcloud,dc=local
  LLDAP_ADMIN_USER default uid=admin,ou=people,<base>
  LLDAP_ADMIN_PASS required

Usage:
  verify-ldap.py                 # list all users + attributes
  verify-ldap.py <uid> [password]# also bind as <uid> to check the password
"""
import os
import sys

import ldap3


def main() -> int:
    base_dn = os.environ.get("LLDAP_BASE_DN", "dc=libcloud,dc=local")
    ldap_url = os.environ.get("LLDAP_LDAP_URL", "ldap://localhost:3890")
    admin_uid = os.environ.get("LLDAP_ADMIN_USER", "admin")
    admin_user = f"uid={admin_uid},ou=people,{base_dn}"
    admin_pass = os.environ.get("LLDAP_ADMIN_PASS")
    if not admin_pass:
        print("LLDAP_ADMIN_PASS is required", file=sys.stderr)
        return 2

    server = ldap3.Server(ldap_url)
    admin = ldap3.Connection(server, user=admin_user, password=admin_pass, auto_bind=True)
    admin.search(
        f"ou=people,{base_dn}",
        "(objectClass=person)",
        attributes=ldap3.ALL_ATTRIBUTES,
    )
    print(f"Users in ou=people,{base_dn}: {len(admin.entries)}")
    for e in admin.entries:
        # Use .values so multi-valued attributes (e.g. role) show every value.
        def vals(a):
            try:
                v = e[a].values
            except (KeyError, IndexError):
                return None
            return ",".join(str(x) for x in v) if isinstance(v, list) else v
        print(f"- uid={vals('uid')}  mail={vals('mail')}  cn={vals('cn')}  "
              f"department={vals('department')}  role={vals('role')}  "
              f"jobtitle={vals('jobtitle')}")
    admin.unbind()

    if len(sys.argv) >= 2:
        uid = sys.argv[1]
        pw = sys.argv[2] if len(sys.argv) >= 3 else None
        if pw is None:
            return 0
        user_dn = f"uid={uid},ou=people,{base_dn}"
        uc = ldap3.Connection(server, user=user_dn, password=pw)
        ok = uc.bind()
        print(f"\nBind as {uid}: {'OK' if ok else 'FAILED'}")
        uc.unbind()
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

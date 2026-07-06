Focusing on the following key questions:   create logs which can help to answer these questions, rewrite the questions into where the logs can be generated

| A1 | Who authenticated to LLDAP (bind), from which IP, when, and did the bind succeed or fail? |
| A2 | Who logged in to Dex (user, OAuth client, redirect_uri, IP) and was the login successful? |
| A3 | Who obtained a Dex-issued JWT (sub, aud, iss, jti, expiry) and when — including from host scripts? |
| A4 | Who authenticated to Vault via the LDAP auth method (user, policies issued, token TTL, IP)? |
| A5 | Are there brute-force / credential-stuffing patterns against LLDAP, Dex, or Vault?  Was there any failed logins?
| A6 | Did a user authenticate from a new / off-hours / unexpected IP or host? |

### B. Authorization & access control

| ID | Question |
|----|----------|
| B1 | For each libcloud REST call: who called, what URL, what provider, what `auth_binding`, what was the OpenFGA decision, and what was the final HTTP status? |
| B2 | For each authenticaed user, what are all the libcloud REST call in sequence: who called, what URL, date time stamp

### D. Resource & cloud operations

| ID | Question |
|----|----------|
| D1 | What cloud resources did a user create/modify/destroy, on which tenant/region/cluster, and what was the cloud-side request id? |
| D3 | Was there access to an unexpected cloud region/cluster for that tenant? |

### E. Lifecycle & offboarding

| ID | Question |
|----|----------|
| E1 | Was a user offboarded in LLDAP but still has OpenFGA tuples / Vault tokens / leases? |
| E2 | Was a tenant created or deleted, and by whom (must be superadmin-gated)? |
| E3 | Was an LLDAP group created/deleted and a member added/removed, by whom? |

| F3 | Are audit logs protected against tampering (append-only, shipped off-host, retained)? |

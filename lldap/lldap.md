
LLDAP is designed to be run as a single container with a small set of environment variables and one persistent volume, making it very straightforward to stand up for development via Docker or docker‑compose. [lldap](https://lldap.com)

## What LLDAP actually provides

- LLDAP is a lightweight LDAP server with an embedded DB (by default) plus a built‑in web UI for managing users, groups, and credentials. [ziggyds](https://ziggyds.be/lldap/)
- It exposes a standard LDAP interface (bind/search) on a configurable port (defaults to 3890 for LDAP, 6360 for LDAPS) and uses a conventional tree rooted at a configurable base DN (for example `dc=example,dc=com`). [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)
- Out of the box, it gives you:  
  - User objects (person entries with `uid`, `displayName`, `mail`, etc.). [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)
  - Group objects (`groupOfUniqueNames`) referencing users via DN membership. [ziggyds](https://ziggyds.be/lldap/)
  - An admin account you use as a “manager DN” for apps that need to search the directory. [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)

This is enough for typical dev uses: centralized user store, group‑based access control, and an LDAP endpoint that most frameworks can talk to.

## Core functions in a dev workflow

For development, LLDAP typically plays these roles: [forum.level1techs](https://forum.level1techs.com/t/centralising-authentication-lldap/248508)

- Central user/group directory for your stack (e.g. local apps, CI, homelab services).  
- Authentication backend for apps that support LDAP/“OpenLDAP” style auth (Rancher, Jenkins, maddy, OPNsense, etc.). [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)
- Backing identity store for an SSO or proxy layer (e.g. Authelia, Traefik/NGINX + auth middleware). [helgeklein](https://helgeklein.com/blog/authelia-lldap-authentication-sso-user-management-password-reset-for-home-networks/)

Functionally, in dev you usually:

- Create users and groups in the web UI.  
- Assign users to groups representing roles/services (e.g. `Rancher`, `Service-Admin`, `Service-User`). [forum.level1techs](https://forum.level1techs.com/t/centralising-authentication-lldap/248508)
- Configure each app to:  
  - Bind with a service account (`cn=admin,ou=people,dc=example,dc=com` or a dedicated read‑only DN). [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)
  - Search `ou=people` for users and `ou=groups` for groups based on filters (e.g. `(&(uid={0})(objectClass=person))`, `(&(uniqueMember={0})(objectclass=groupOfUniqueNames))`). [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)

## Minimal Docker Compose setup

A minimal compose for dev follows the official image and a small set of environment variables; conceptually: [hub.docker](https://hub.docker.com/r/lldap/lldap)

```yaml
version: "3.8"

services:
  lldap:
    image: lldap/lldap:latest
    container_name: lldap
    hostname: lldap
    ports:
      - "3890:3890"    # LDAP
      - "17170:17170"  # Web UI
      # optionally: "6360:6360" for LDAPS
    volumes:
      - lldap_data:/data
    environment:
      # Run the container as your host user if desired
      - UID=1000
      - GID=1000

      # Security-critical secrets
      - LLDAP_JWT_SECRET=changeme-long-random
      - LLDAP_LDAP_USER_PASS=changeme-admin-password

      # Directory layout
      - LLDAP_LDAP_BASE_DN=dc=example,dc=com

      # Optional: tuning, mail domain, etc.
      # - LLDAP_SMTP_HOST=...
      # - LLDAP_SMTP_FROM=...

volumes:
  lldap_data:
```

Key points from the actual examples: [goneuland](https://goneuland.de/lldap/)

- `/data` is the persistent volume; on first run, the entrypoint copies a template config `lldap_config.docker_template.toml` into `/data/lldap_config.toml`, which you can later edit if you need more advanced tweaks. [github](https://github.com/lldap/lldap/blob/main/docker-entrypoint-rootless.sh)
- `LLDAP_JWT_SECRET` is used by the web UI/API for session tokens; generate a long random value even in dev. [goneuland](https://goneuland.de/lldap/)
- `LLDAP_LDAP_USER_PASS` sets the initial admin password (user `admin`); you log into the web UI with `admin` and this password. [ziggyds](https://ziggyds.be/lldap/)
- `LLDAP_LDAP_BASE_DN` defines the root of your directory tree (e.g. `dc=example,dc=com` or `dc=yourdomain,dc=tld`). [goneuland](https://goneuland.de/lldap/)

Once the container is up, you can:

- Open `http://localhost:17170` (or via your reverse proxy) to reach the web UI. [ziggyds](https://ziggyds.be/lldap/)
- Log in as `admin` with the password you set.  
- Create users (`uid`, `displayName`, `mail`, etc.) and groups (`cn`, membership). [ziggyds](https://ziggyds.be/lldap/)

## Typical dev configuration for client apps

Most client apps don’t have a “LLDAP” option; you just choose “Generic LDAP/OpenLDAP” and plug in LLDAP endpoints: [forum.level1techs](https://forum.level1techs.com/t/centralising-authentication-lldap/248508)

**Example generic LDAP settings (pattern):**

- LDAP URL: `ldap://lldap:3890` (inside Docker network) or `ldap://host:3890` (external). [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)
- Manager/Bind DN: `uid=admin,ou=people,dc=example,dc=com` or `cn=admin,ou=people,dc=example,dc=com` depending on how you created the admin user. [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)
- Manager password: the same as `LLDAP_LDAP_USER_PASS` or the dedicated service account’s password. [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)
- User search base: `ou=people,dc=example,dc=com`. [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)
- Group search base: `ou=groups,dc=example,dc=com`. [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)

**Example filters (from provided configs):**

- User filter: `(&(uid={0})(objectclass=person))` for username‑based login. [github](https://github.com/lldap/lldap/blob/main/example_configs/onedev.md)
- Group filter:  
  - `(&(uniqueMember={0})(objectclass=groupOfUniqueNames))` (Rancher example). [ziggyds](https://ziggyds.be/lldap/)
- For mail‑based auth (maddy), you might use:  
  - `filter "(&(objectClass=person)(uid={username}))"` or  
  - `filter "(&(objectClass=person)(mail={username}))"` or  
  - `filter "(&(|(uid={username})(mail={username}))(objectClass=person))"` to accept both. [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)  

These patterns are reused across OPNsense, Rancher, maddy, Authelia, etc., with the only differences being how each app names the fields. [helgeklein](https://helgeklein.com/blog/authelia-lldap-authentication-sso-user-management-password-reset-for-home-networks/)

## Function and infra requirements in development

From an infra/dev perspective, running LLDAP via Docker in a dev environment implies: [lldap](https://lldap.com)

- **Runtime & storage**  
  - One container, minimal CPU/RAM footprint; fine on a dev box or homelab node. [hub.docker](https://hub.docker.com/r/lldap/lldap)
  - A single persistent volume for `/data` holding the DB and configuration. [github](https://github.com/lldap/lldap/blob/main/docker-entrypoint-rootless.sh)

- **Network**  
  - Expose LDAP port(s) (`3890`, optionally `6360`) to your dev network or overlay/bridge network so apps can connect. [goneuland](https://goneuland.de/lldap/)
  - Expose the web UI port (`17170`) either directly or via a reverse proxy (NGINX, Traefik) with TLS. [forum.level1techs](https://forum.level1techs.com/t/centralising-authentication-lldap/248508)

- **Security (even in dev)**  
  - Unique, non‑trivial `LLDAP_JWT_SECRET` and admin password. [goneuland](https://goneuland.de/lldap/)
  - Optionally restrict exposure to a Docker network (no public ports) and use a proxy/SSO front‑end (e.g. Authelia) even in dev for closer parity with prod. [helgeklein](https://helgeklein.com/blog/authelia-lldap-authentication-sso-user-management-password-reset-for-home-networks/)

- **Schema/structure**  
  - Decide your base DN up front (`dc=corp,dc=local`, `dc=example,dc=com`) so you don’t have to refactor later. [github](https://github.com/lldap/lldap/blob/main/example_configs/maddy.md)
  - Use consistent OUs (`ou=people`, `ou=groups`) across environments, because many sample configs assume this layout. [ziggyds](https://ziggyds.be/lldap/)

Given your background, you can treat LLDAP as “a small IAM component” that you version/configure via compose + env, and wire into the rest of your dev stack like any other service.


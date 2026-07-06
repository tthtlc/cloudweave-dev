
cd openfga_my and
run setup.sh (will setup vault and dex)

Generated ephemeral LIBCLOUD_OIDC_CLIENT_SECRET (also written to /home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env).
Rendering Dex config (LDAP connector → LLDAP) ...
04:00:11  INFO     Wrote /home/ubuntu/libcloud_nutanix/openfga_my/../dex/config.yaml
04:00:11  INFO     Wrote /home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env
{
  "dex_env": "/home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env",
  "issuer": "http://localhost:5556/dex/",
  "client_id": "libcloud-rest",
  "internal_url": "http://localhost:5556"
}
Starting LLDAP ...
[+] up 1/1
 ✔ Container lldap Running                                                                                                                                  0.0s
Waiting for LLDAP web UI ...
[+] up 1/1
 ✔ Container lldap Running                                                                                                                                  0.0s
Attaching to bootstrap-1
Container lldap Waiting 
Container lldap Healthy 
bootstrap-1  | Waiting for LLDAP web UI at http://lldap:17170 ...
bootstrap-1  | Authenticating as admin ...
bootstrap-1  | Creating custom user attributes ...
bootstrap-1  |   = department already exists (Database error: `Execution Error: error returned from database: (code: 1555) UNIQUE constraint failed: user_attribute_schema.user_attribute_schema_name`)
bootstrap-1  |   = role already exists (Database error: `Execution Error: error returned from database: (code: 1555) UNIQUE constraint failed: user_attribute_schema.user_attribute_schema_name`)
bootstrap-1  |   = jobtitle already exists (Database error: `Execution Error: error returned from database: (code: 1555) UNIQUE constraint failed: user_attribute_schema.user_attribute_schema_name`)
bootstrap-1  | Current user attribute schema:
bootstrap-1  | [
bootstrap-1  |   {
bootstrap-1  |     "name": "avatar",
bootstrap-1  |     "attributeType": "JPEG_PHOTO",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "creation_date",
bootstrap-1  |     "attributeType": "DATE_TIME",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": false,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "department",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": false
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "display_name",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "first_name",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "jobtitle",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": false
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "last_name",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "mail",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "modified_date",
bootstrap-1  |     "attributeType": "DATE_TIME",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": false,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "password_modified_date",
bootstrap-1  |     "attributeType": "DATE_TIME",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": false,
bootstrap-1  |     "isHardcoded": true
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "role",
bootstrap-1  |     "attributeType": "STRING",
bootstrap-1  |     "isList": false,
bootstrap-1  |     "isEditable": true,
bootstrap-1  |     "isHardcoded": false
bootstrap-1  |   },
bootstrap-1  |   {
bootstrap-1  |     "name": "user_id",
bootstrap-1  |     "attributeType": "STRING",

bootstrap-1 exited with code 0
bootstrap-1  |     "isList": false,

Creating superadmin in LLDAP (break-glass via LLDAP admin) ...
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-ea27657717e4 Creating 
Container lldap-lldap-tools-run-ea27657717e4 Created 
LLDAP user superadmin already exists — syncing password ...
Password set for superadmin (uid=superadmin,ou=people,dc=libcloud,dc=local)
OK superadmin
Starting OpenFGA + Dex + Vault ...
[+] up 2/2
 ✔ Container openfga         Running                                                                                                                        0.0s
 ✔ Container openfga-migrate Exited                                                                                                                         0.7s
[+] up 1/1
 ✔ Container dex Running                                                                                                                                    0.0s
[+] up 1/1
 ✔ Container vault Running                                                                                                                                  0.0s
Waiting for Dex OIDC discovery ...
04:00:17  INFO     Wrote /home/ubuntu/libcloud_nutanix/openfga_my/../dex/config.yaml
04:00:17  INFO     Wrote /home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env
04:00:17  INFO     Dex OIDC discovery available at http://localhost:5556/dex/.well-known/openid-configuration
{
  "dex_env": "/home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env",
  "issuer": "http://localhost:5556/dex/",
  "client_id": "libcloud-rest",
  "internal_url": "http://localhost:5556"
}
[+] up 1/1
 ✔ Container dex Started                                                                                                                                    0.6s
Authenticating as superadmin (gating credential) ...
Logging in to Dex as superadmin ...
Verifying superadmin JWT ...
superadmin JWT verified (sub=CgpzdXBlcmFkbWluEgVsbGRhcA, email=superadmin@libcloud.local)
SUPERADMIN_JWT exported (length=750).
  superadmin JWT acquired and verified.
Creating per-cloud tenant users in LLDAP (gated by superadmin) ...
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-b160ee93090e Creating 
Container lldap-lldap-tools-run-b160ee93090e Created 
LLDAP user aws-owner already exists — syncing password ...
Password set for aws-owner (uid=aws-owner,ou=people,dc=libcloud,dc=local)
OK aws-owner
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-8ed42a0317cd Creating 
Container lldap-lldap-tools-run-8ed42a0317cd Created 
LLDAP user aws-admin already exists — syncing password ...
Password set for aws-admin (uid=aws-admin,ou=people,dc=libcloud,dc=local)
OK aws-admin
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-9f7d8eeec11d Creating 
Container lldap-lldap-tools-run-9f7d8eeec11d Created 
LLDAP user aws-viewer already exists — syncing password ...
Password set for aws-viewer (uid=aws-viewer,ou=people,dc=libcloud,dc=local)
OK aws-viewer
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-340239c16fcf Creating 
Container lldap-lldap-tools-run-340239c16fcf Created 
LLDAP user ntnx-owner already exists — syncing password ...
Password set for ntnx-owner (uid=ntnx-owner,ou=people,dc=libcloud,dc=local)
OK ntnx-owner
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-3e00cd94a6fc Creating 
Container lldap-lldap-tools-run-3e00cd94a6fc Created 
LLDAP user ntnx-admin already exists — syncing password ...
Password set for ntnx-admin (uid=ntnx-admin,ou=people,dc=libcloud,dc=local)
OK ntnx-admin
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-b6cddb964292 Creating 
Container lldap-lldap-tools-run-b6cddb964292 Created 
LLDAP user ntnx-viewer already exists — syncing password ...
Password set for ntnx-viewer (uid=ntnx-viewer,ou=people,dc=libcloud,dc=local)
OK ntnx-viewer
[+]  1/1t 1/11
 ✔ Container lldap Running                                                                                                                                  0.0s
Container lldap Waiting 
Container lldap Healthy 
Container lldap-lldap-tools-run-9e7886c157e9 Creating 
Container lldap-lldap-tools-run-9e7886c157e9 Created 
LLDAP user cloud-denied already exists — syncing password ...
Password set for cloud-denied (uid=cloud-denied,ou=people,dc=libcloud,dc=local)
OK cloud-denied
Waiting for OpenFGA bootstrap (superadmin-gated) ...
[+] up 2/2
 ✔ Container openfga           Running                                                                                                                      0.0s
 ✔ Container openfga-bootstrap Recreated                                                                                                                    0.2s
Attaching to openfga-bootstrap
openfga-bootstrap  | 04:00:33  INFO     OpenFGA bootstrap targeting http://openfga:8080 (store='libcloud-rest-store')
openfga-bootstrap  | 04:00:33  INFO     Reusing existing store 'libcloud-rest-store' (id=01KW9EZ0Q706Y580FGQ2488THC)
openfga-bootstrap  | 04:00:33  INFO     Latest authorization model already matches (id=01KWCSRHRR4ADZPJYGSQ52GENX) — skipping write
openfga-bootstrap  | 04:00:33  INFO     All 17 seed tuples already present — nothing to write
openfga-bootstrap  | 04:00:33  INFO     Validating deployment with 33 check(s) ...
openfga-bootstrap  | 04:00:33  INFO     ✅ All 33 validation checks passed
openfga-bootstrap  | 04:00:33  INFO     Bootstrap complete — store_id=01KW9EZ0Q706Y580FGQ2488THC model_id=01KWCSRHRR4ADZPJYGSQ52GENX
openfga-bootstrap  | 04:00:33  INFO     Wrote generated/fga.env
openfga-bootstrap  | {
openfga-bootstrap  |   "store_id": "01KW9EZ0Q706Y580FGQ2488THC",
openfga-bootstrap  |   "model_id": "01KWCSRHRR4ADZPJYGSQ52GENX"
openfga-bootstrap  | }
openfga-bootstrap exited with code 0
Bootstrapping Vault (superadmin-gated; seeds cloud creds from env) ...
[+] up 2/2
 ✔ Container vault           Running                                                                                                                        0.0s
 ✔ Container vault-bootstrap Recreated                                                                                                                      0.2s
Attaching to vault-bootstrap
vault-bootstrap  | 04:00:34  INFO     Vault already initialized (using stored root token + unseal key)
vault-bootstrap  | 04:00:34  INFO     Unsealing Vault ...
vault-bootstrap  | 04:00:34  INFO     Vault unsealed
vault-bootstrap  | 04:00:34  INFO     KV v2 enabled at secret/
vault-bootstrap  | 04:00:34  INFO     Ensured ACL policy libcloud-rest-read
vault-bootstrap  | 04:00:34  INFO     Issued libcloud REST API read token (policy=libcloud-rest-read)
vault-bootstrap  | {
vault-bootstrap  |   "vault_env": "/bootstrap/generated/vault.env",
vault-bootstrap  |   "vault_addr": "http://localhost:8200",
vault-bootstrap  |   "kv_path_prefix": "secret/libcloud",
vault-bootstrap  |   "read_policy": "libcloud-rest-read",
vault-bootstrap  |   "note": "per-tenant credentials are seeded by scripts/set_tenant_credentials.py (owner-gated)"
vault-bootstrap  | }
vault-bootstrap  | 04:00:34  INFO     Wrote /bootstrap/generated/vault.env
vault-bootstrap exited with code 0
Syncing OpenFGA IDs -> libcloud.rest ...
  libcloud.rest FGA IDs already current — no restart needed
Syncing Vault credentials -> libcloud.rest ...
  Updated libcloud.rest VAULT_ADDR / VAULT_TOKEN
  Recreating libcloud-rest-api container to apply Vault env
[+] Building 2.2s (18/18) FINISHED                                                                                                                              
 => [internal] load local bake definitions                                                                                                                 0.0s
 => => reading from stdin 530B                                                                                                                             0.0s
 => [internal] load build definition from Dockerfile                                                                                                       0.0s
 => => transferring dockerfile: 976B                                                                                                                       0.0s
 => [internal] load metadata for docker.io/library/python:3.12-slim                                                                                        0.0s
 => [internal] load .dockerignore                                                                                                                          0.0s
 => => transferring context: 2B                                                                                                                            0.0s
 => [ 1/11] FROM docker.io/library/python:3.12-slim@sha256:6c4dd321d176d61ea848dc8c73a4f7dbae8f70e0ee48bb411ea2f045b599fa8e                                0.0s
 => => resolve docker.io/library/python:3.12-slim@sha256:6c4dd321d176d61ea848dc8c73a4f7dbae8f70e0ee48bb411ea2f045b599fa8e                                  0.0s
 => [internal] load build context                                                                                                                          0.9s
 => => transferring context: 852.05kB                                                                                                                      0.8s
 => CACHED [ 2/11] WORKDIR /app                                                                                                                            0.0s
 => CACHED [ 3/11] RUN apt-get update     && apt-get install -y --no-install-recommends curl     && rm -rf /var/lib/apt/lists/*                            0.0s
 => CACHED [ 4/11] COPY libcloud.rest/requirements.txt .                                                                                                   0.0s
 => CACHED [ 5/11] RUN pip install --no-cache-dir -r requirements.txt                                                                                      0.0s
 => CACHED [ 6/11] COPY libcloud /libcloud                                                                                                                 0.0s
 => CACHED [ 7/11] RUN pip install --no-cache-dir /libcloud                                                                                                0.0s
 => [ 8/11] COPY libcloud.rest/app ./app                                                                                                                   0.1s
 => [ 9/11] COPY libcloud.rest/data ./data-seed                                                                                                            0.0s
 => [10/11] COPY libcloud.rest/docker/entrypoint.sh /entrypoint.sh                                                                                         0.0s
 => [11/11] RUN chmod +x /entrypoint.sh     && useradd --create-home --shell /usr/sbin/nologin appuser     && mkdir -p /app/data     && chown -R appuser:  0.4s
 => exporting to image                                                                                                                                     0.4s
 => => exporting layers                                                                                                                                    0.2s
 => => exporting manifest sha256:69cc6be59a63c5fc5840d15e4a1ad5163d41750f413e6dc7df1217c588906c06                                                          0.0s
 => => exporting config sha256:16ea5b6c205c0640e9ec129397805eca09f2a89e0e5c803a643b6fe0076cd49d                                                            0.0s
 => => exporting attestation manifest sha256:fa2369ca93c861811707a369645b803401e28996f32d8d79209a0d68d3254518                                              0.0s
 => => exporting manifest list sha256:0ab3d1acea91380d5a8920795205bab1d6e792ce2b380eed565374d6cb9cddb9                                                     0.0s
 => => naming to docker.io/library/libcloud-rest-api:latest                                                                                                0.0s
 => => unpacking to docker.io/library/libcloud-rest-api:latest                                                                                             0.1s
 => resolving provenance for metadata file                                                                                                                 0.0s
[+] up 2/2
 ✔ Image libcloud-rest-api:latest Built                                                                                                                     2.3s
 ✔ Container libcloud-rest-api    Started                                                                                                                   0.9s

Setup complete.
  OpenFGA env  : /home/ubuntu/libcloud_nutanix/openfga_my/generated/fga.env
  Dex OIDC     : /home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env
  Vault        : /home/ubuntu/libcloud_nutanix/openfga_my/../vault/generated/vault.env

Identity model:
  superadmin   / SA-alAKiKrUf5I1xhO9Ogwljwfk   (bootstrap: Vault/OpenFGA/LLDAP admin)
  aws-owner    / SA-Jv07tZKzzFB85mKAL_rbphi_    (owner  of tenant:aws)
  aws-admin    / SA-YxB5zqiYyA8M0mscsjfOkuWd    (admin  of tenant:aws -> provision AWS)
  aws-viewer   / SA-SSxoqVYaKcnOLZX88Kkxe3AA   (viewer of tenant:aws -> enumerate only)
  ntnx-owner   / SA-9HXuDFerBkabyaDw2tG-t7O-   (owner  of tenant:nutanix)
  ntnx-admin   / SA-4ckgB21zNYj4B_cRlh2BFQp-   (admin  of tenant:nutanix -> provision Nutanix)
  ntnx-viewer  / SA-OZlrfS1FP9wP_-Vglx30-n3R  (viewer of tenant:nutanix -> enumerate only)
  cloud-denied / CloudDenied123! (authenticated but denied)

Cloud backend credentials are per-tenant and NOT set by setup.sh.
Each tenant's OWNER writes its credentials to Vault (gated by OpenFGA
can_manage_credentials; admins/viewers cannot):
  TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_AWS_OWNER \
    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
    python3 scripts/set_tenant_credentials.py
  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \
    python3 scripts/set_tenant_credentials.py
superadmin (owner on both tenants) can set them too.

Then run:
  LIBCLOUD_USER=aws-admin   ./scripts/provision_aws.sh
  LIBCLOUD_USER=aws-viewer  ./scripts/provision_aws.sh
  LIBCLOUD_USER=ntnx-admin  ./scripts/provision_nutanix.sh
  LIBCLOUD_USER=ntnx-viewer ./scripts/provision_nutanix.sh

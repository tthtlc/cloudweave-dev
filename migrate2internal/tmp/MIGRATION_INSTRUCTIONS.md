# Migrate libcloud-nutanix Docker Stack to Internal Server

## Overview

These scripts perform a full offline migration of the libcloud-nutanix Docker
stack from the **source machine** (167.172.94.123, internet-reachable) to the
**isolated destination machine** (10.0.16.227, reachable only through bastion
at 13.212.232.220).

```
┌─────────────┐         ┌──────────┐         ┌──────────────┐
│   SOURCE    │  rsync  │ BASTION  │  rsync  │ DESTINATION  │
│ 167.172...  │────────▶│13.212... │────────▶│ 10.0.16.227  │
│  (public)   │         │ (jump)   │         │  (isolated)  │
└─────────────┘         └──────────┘         └──────────────┘
```

## What gets migrated

| Component | Method |
|-----------|--------|
| Docker + Compose binaries | .deb package bundle (offline install) |
| Container images | `docker save` → tarball → `docker load` |
| Project files | tar archive of /home/ubuntu/libcloud_nutanix/ |
| Named volumes (Postgres, Vault, LLDAP, etc.) | tar of /var/lib/docker/volumes/<name>/_data |
| Bind-mounted configs/secrets | tar of each bind-mount source path |
| SSH key + config | Copied for continued bastion access |

## Services migrated

| Service | Image | Type |
|---------|-------|------|
| **openfga-postgres** | postgres:16 | Stock image |
| **openfga** | openfga-local:latest | Custom built |
| **lldap** | lldap/lldap:latest | Stock image |
| **dex** | ghcr.io/dexidp/dex:v2.41.1 | Stock image |
| **vault** | hashicorp/vault:1.15 | Stock image |
| **portal** | server-portal:latest | Custom built |
| **identity-service** | libcloud-identity-service:latest | Custom built |
| **libcloud-rest-api** | libcloud-rest-api:latest | Custom built |
| **openfga-visualizer** | openfga-rbac-visualizer | Custom built |
| **libcloud-swagger-ui** | swaggerapi/swagger-ui:v5.18.2 | Stock image |
| **stoplight-prism** | stoplight/prism:5 | Stock image |
| **stoplight-emulator** | stoplight_mock-emulator | Custom built |

## Persistent data migrated

| Volume | Contents |
|--------|----------|
| `openfga_postgres_openfga-pg-data` | PostgreSQL data (OpenFGA tuples, authz model) |
| `lldap_lldap_data` | LLDAP user directory (all users, groups) |
| `vault_vault-data` | Vault file storage (encrypted cloud credentials) |
| `libcloudrest_api-data` | Libcloud REST API persistent data |
| `openfga_my_openfga-data` | Legacy OpenFGA data (if exists) |

## Step-by-step instructions

### Phase 1: Source machine — create the backup

On the **source machine** (167.172.94.123), logged in as `ubuntu`:

```bash
# Navigate to the scripts directory
cd /home/ubuntu/libcloud_nutanix/migrate2internal

# Make all scripts executable
chmod +x backup-system.sh transfer-backup.sh restore-system.sh

# Run the backup (takes a few minutes, mostly volume tarballs)
./backup-system.sh
```

**What happens:**
1. Downloads Docker .deb packages to `~/offline/docker-debs/`
2. Saves all container images to `~/offline/backup/images/stack-images.tar`
3. Records all mounts to `~/offline/backup/mounts.txt`
4. Archives the entire project to `~/offline/backup/project/project-files.tgz`
5. Tarballs each named volume to `~/offline/backup/volumes/<name>.tgz`
6. Tarballs each bind-mount source to `~/offline/backup/binds/`
7. Copies SSH key and config
8. Generates checksums and a MANIFEST.txt

**Output:** Everything lives under `~/offline/`:
```
~/offline/
├── docker-debs/           # Docker .deb packages + SHA256SUMS
└── backup/
    ├── images/             # stack-images.tar + images.txt
    ├── project/            # project-files.tgz
    ├── volumes/            # <volume-name>.tgz per named volume
    ├── binds/              # <idx>-<path>.tgz per bind mount + bind-map.txt
    ├── mounts.txt          # mount inventory
    ├── volume-names.txt    # volume name list
    ├── bind-sources.txt    # bind source path list
    ├── MANIFEST.txt        # human-readable manifest
    ├── SHA256SUMS          # checksums for everything
    └── libcloud-private-key.pem
```

### Phase 2: Transfer to destination

On the **source machine** (167.172.94.123):

```bash
cd /home/ubuntu/libcloud_nutanix/migrate2internal
./transfer-backup.sh
```

**What happens:** Rsync copies `~/offline/` over SSH through the bastion to
the internal machine at `/home/ubuntu/offline/`.

**If the transfer is interrupted:**
```bash
./transfer-backup.sh --resume     # Continues partial transfer
```

**To preview what will be transferred:**
```bash
./transfer-backup.sh --dry-run
```

**Estimated transfer time:** Depends on volume sizes. The Postgres data volume
is typically the largest. Use `du -sh ~/offline/` to check total size.

**Manual alternative if rsync isn't suitable:**
```bash
# On the source machine, create a single tarball
cd ~
tar -czf offline-full.tgz offline/

# Copy through bastion to internal
scp -o ProxyJump=bastion offline-full.tgz internal:/home/ubuntu/

# On internal, extract
ssh internal "cd /home/ubuntu && tar -xzf offline-full.tgz"
```

### Phase 3: Destination machine — restore

On the **destination machine** (10.0.16.227), logged in as `ubuntu`:

First, copy the restore script to the destination:
```bash
# From the source machine:
scp restore-system.sh internal:/home/ubuntu/
```

Then on the destination:
```bash
ssh internal
cd /home/ubuntu
chmod +x restore-system.sh

# Preview what will happen (optional):
DRY_RUN=1 ./restore-system.sh

# Run the actual restore:
./restore-system.sh
```

**What happens:**
1. Removes conflicting distro Docker packages (if any)
2. Installs Docker + Compose from the offline .deb bundle
3. Loads all container images from `stack-images.tar`
4. Extracts project files to `/home/ubuntu/libcloud_nutanix/`
5. Restores SSH key and config
6. Recreates Docker networks
7. Recreates named volumes and restores their data
8. Restores bind-mount contents
9. Verifies `.env` file presence
10. Starts all compose projects in dependency order
11. Verifies with `docker ps`

### Phase 4: Verify

On the destination machine, check that everything is healthy:

```bash
# Check all containers are running
docker ps

# Individual health checks
curl -s http://localhost:8766/health        # identity service
curl -s http://localhost:8765/health        # libcloud REST API
curl -s http://localhost:3000               # portal
curl -s http://localhost:8081/healthz       # OpenFGA
curl -s http://localhost:8200/v1/sys/health # Vault
curl -s http://localhost:5556/dex/healthz   # Dex (if exposed)

# Check Postgres connectivity
psql -h localhost -p 5433 -U openfga -d openfga -c "SELECT 1;"

# Check LLDAP
ldapsearch -H ldap://localhost:3890 -x -D "uid=admin,ou=people,dc=example,dc=com" \
    -W -b "dc=example,dc=com"
```

## Troubleshooting

### Transfer fails with "Permission denied (publickey)"

```bash
# Verify the key is present and has correct permissions
ls -la ~/.ssh/libcloud-private-key.pem
chmod 600 ~/.ssh/libcloud-private-key.pem

# Test connectivity step by step
ssh bastion echo "bastion OK"
ssh -o ProxyJump=bastion internal echo "internal OK"
```

### Docker won't start after .deb install

```bash
# Check systemd status
sudo systemctl status docker
sudo journalctl -xeu docker

# If containerd conflicts, purge and reinstall
sudo apt purge -y containerd containerd.io
sudo apt install -y ~/offline/docker-debs/*.deb
```

### Volumes restore but data is wrong

Check that volume names match. The volume paths on the destination must be
identical to the source because data was archived from specific paths under
`/var/lib/docker/volumes/<name>/_data`.

### Bind mounts fail because parent directories don't exist

The restore script creates parent directories automatically with `mkdir -p`.
If a bind source was an absolute path outside `/home/ubuntu/` (none currently
are), you may need to create those manually.

### .env file is missing or wrong

The `.env` file is included in the project files tarball. If it's missing:
```bash
ls -la /home/ubuntu/libcloud_nutanix/.env
```
If the internal machine needs different values (e.g., different IP/hostname),
edit `.env` before starting the stack. Key variables that may differ:
- `DEX_PUBLIC_URL` — the externally-visible Dex URL
- `NUTANIX_HOST` — Nutanix cluster hostname/IP
- `AWS_REGION` — AWS region

## Script files

| File | Run on | Purpose |
|------|--------|---------|
| `backup-system.sh` | Source (167.172.94.123) | Create the full backup set |
| `transfer-backup.sh` | Source (167.172.94.123) | Copy backup to destination via bastion |
| `restore-system.sh` | Destination (10.0.16.227) | Restore everything and start the stack |

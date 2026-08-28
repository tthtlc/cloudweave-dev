Yes—use `docker save` on the present machine and `docker load` on the isolated one for the images, but that is only part of the migration.  For a clean restore, move four things together: the Docker/Compose `.deb` packages, the image tarball, the Compose/project files, and the persistent data from volumes or bind mounts.

## Host match

The present machine (or so-called "source machine", IP is 167.172.94.123) is Ubuntu 24.04.3 LTS (`noble`) on `x86_64`, and the isolated destination machine (internal IP is not reachable from internet, but "ssh internal" and scp internal" both can reach there, going through the bastion host - see ~/.ssh/config for detail configuration) is Ubuntu 24.04.4 LTS (`noble`) on `x86_64`.

## What to move

The package set Docker documents for Ubuntu is `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin`, and Compose on Linux is delivered through the `docker-compose-plugin` package.  Docker also documents that `docker image save` creates a backup that can later be restored with `docker load`, while volume data must be restored separately from image data. [docs.docker](https://docs.docker.com/compose/install/linux/)

- Docker offline package bundle: the five Docker `.deb` packages above, plus any dependency `.deb` files downloaded with them. 
- Images: one or more tar files produced by `docker save`. [docs.docker](https://docs.docker.com/reference/cli/docker/image/save/)
- Project files: `compose.yml`, override files, `.env`, custom configs, secrets material, and any local scripts.
- Persistent state: named volumes and bind-mounted host directories, because image restore alone does not restore volume data. [docs.docker](https://docs.docker.com/desktop/settings-and-maintenance/backup-and-restore/)

## Source machine

Use the connected source host to download the Docker package bundle and to create the application backup set, because it already matches the destination OS family and architecture.  I would not use `docker export`/`docker import` as the primary method here; restore the stack from images plus state instead. 

```bash
# 1) Prepare Docker repository on the connected source machine
sudo apt update
sudo apt install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

# 2) Download Docker + Compose packages and dependencies without installing on destination
mkdir -p ~/offline/docker-debs
cd ~/offline/docker-debs
sudo apt clean
sudo apt install --download-only -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

cp /var/cache/apt/archives/*.deb .
sha256sum *.deb > SHA256SUMS
```

Use this on the source host to back up the running stack as images, project files, and persistent data. [docs.docker](https://docs.docker.com/reference/cli/docker/image/save/)

```bash
mkdir -p ~/offline/backup/{images,project,volumes,binds}
cd ~/offline/backup

# 3) Save all images currently used by containers
docker inspect -f '{{.Config.Image}}' $(docker ps -aq) | sort -u > images/images.txt
docker save -o images/stack-images.tar $(tr '\n' ' ' < images/images.txt)

# 4) Record mounts so you know what state must be restored
docker ps -aq | while read c; do
  echo "=== $c $(docker inspect -f '{{.Name}}' "$c")"
  docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%s|%s\n" .Type .Name .Source .Destination}}{{end}}' "$c"
done | tee mounts.txt

# 5) Back up your compose project and configs
# Replace /path/to/project with the real path
tar -czf project/project-files.tgz /path/to/project

# 6) Back up named volumes
awk -F'|' '$1=="volume" && $2!="" {print $2}' mounts.txt | sort -u > volume-names.txt
while read v; do
  sudo tar --numeric-owner -czf "volumes/${v}.tgz" \
    -C "/var/lib/docker/volumes/${v}/_data" .
done < volume-names.txt

# 7) Back up bind-mounted host paths shown in mounts.txt
# Example only; create one archive per bind source path you actually use
# sudo tar --numeric-owner -czf binds/opt-app-config.tgz -C / opt/app/config
# sudo tar --numeric-owner -czf binds/srv-data.tgz -C / srv/data
```

Then copy `~/offline/docker-debs/` and `~/offline/backup/` to the isolated machine by your allowed ingress path.

## Destination machine

Install Docker from the copied `.deb` files first, then load the images, restore the project files, recreate the volumes, restore the volume contents, restore any bind mounts to their original host paths, and only then start the stack.  If the destination already has distro-provided Docker packages, remove the conflicting packages Docker lists before installing the copied bundle. [docs.docker](https://docs.docker.com/compose/install/linux/)

```bash
# 1) Optional: remove conflicting distro packages if present
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc || true

# 2) Install Docker + Compose from the copied package bundle
cd ~/offline/docker-debs
sudo apt install -y ./*.deb

sudo systemctl enable --now docker
docker --version
docker compose version
```

Use this on the isolated destination host to restore the stack. [docs.docker](https://docs.docker.com/desktop/settings-and-maintenance/backup-and-restore/)

```bash
cd ~/offline/backup

# 3) Load images
docker load -i images/stack-images.tar

# 4) Restore project files
sudo tar -xzf project/project-files.tgz -C /

# 5) Recreate named volumes before restoring data
while read v; do
  docker volume create "$v"
done < volume-names.txt

# 6) Restore named-volume contents
while read v; do
  sudo tar --numeric-owner -xzf "volumes/${v}.tgz" \
    -C "/var/lib/docker/volumes/${v}/_data"
done < volume-names.txt

# 7) Restore bind mounts to their original host paths
# Example only; adapt to your actual archives
# sudo tar --numeric-owner -xzf binds/opt-app-config.tgz -C /
# sudo tar --numeric-owner -xzf binds/srv-data.tgz -C /

# 8) Start the stack
cd /path/to/project
docker compose up -d

# 9) Verify
docker ps
docker compose ps
```

For your case, the best operational pattern is: install Docker offline from copied Noble/amd64 `.deb` files, restore images with `docker load`, restore state separately, and recreate the services from Compose rather than trying to revive container instances directly.  Do you want a hardened two-script version next, with one script for the source host and one for the isolated destination host? 

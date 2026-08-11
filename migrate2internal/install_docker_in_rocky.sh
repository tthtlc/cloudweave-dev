
# 1. Update installed packages
sudo dnf upgrade -y

# 2. Install the DNF repository-management plugin
sudo dnf install -y dnf-plugins-core

# 3. Add Docker's official RHEL repository
sudo dnf config-manager --add-repo \
  https://download.docker.com/linux/rhel/docker-ce.repo

# 4. Install Docker Engine, CLI, containerd, Buildx, and Docker Compose v2
sudo dnf install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# 5. Start Docker now and on every boot
sudo systemctl enable --now docker

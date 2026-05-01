#!/usr/bin/env bash
# =============================================================================
# setup.sh — Common post-install hardening and configuration
# Runs inside the VM during the Packer build via shell provisioner.
# =============================================================================
set -euo pipefail

echo "==> Waiting for apt lock to be released..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 2
done

echo "==> Updating package index..."
apt-get update -y

echo "==> Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  -o Dpkg::Options::="--force-confnew" \
  -o Dpkg::Options::="--force-confdef"

echo "==> Installing common utilities..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl \
  wget \
  vim \
  git \
  unzip \
  net-tools \
  dnsutils \
  htop \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common

echo "==> Cleaning up apt cache..."
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> Disabling swap..."
swapoff -a
# Remove swap entry from fstab (if present)
sed -i '/\bswap\b/d' /etc/fstab

echo "==> Configuring sysctl for better VM performance..."
cat > /etc/sysctl.d/99-packer.conf << 'EOF'
# Reduce swap tendency for a VM
vm.swappiness = 10
# Increase inotify limits (useful for dev/CI workloads)
fs.inotify.max_user_watches = 524288
EOF
sysctl --system

echo "==> Removing SSH host keys (will be regenerated on first boot of each clone)..."
rm -f /etc/ssh/ssh_host_*

echo "==> Configuring SSH to regenerate host keys on first boot..."
cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
# Regenerate SSH host keys on first boot (after template clone)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  dpkg-reconfigure openssh-server
fi
exit 0
RCEOF
chmod +x /etc/rc.local

echo "==> Hardening SSH configuration..."
cat >> /etc/ssh/sshd_config.d/99-packer-hardening.conf << 'EOF'
# Packer build hardening — adjust after deployment as needed
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
EOF

if [[ -n "${ADMIN_USERNAME:-}" ]]; then
  echo "==> Ensuring user ${ADMIN_USERNAME} exists..."
  if ! id "${ADMIN_USERNAME}" &>/dev/null; then
    useradd -m -s /bin/bash "${ADMIN_USERNAME}"
    usermod -aG sudo "${ADMIN_USERNAME}"
    echo "${ADMIN_USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${ADMIN_USERNAME}"
    chmod 0440 "/etc/sudoers.d/${ADMIN_USERNAME}"
  fi

  if [[ -n "${ADMIN_GITHUB_USER:-}" ]]; then
    echo "==> Importing SSH public keys from GitHub (${ADMIN_GITHUB_USER}) for user ${ADMIN_USERNAME}..."
    sudo -u "${ADMIN_USERNAME}" ssh-import-id-gh "${ADMIN_GITHUB_USER}"
  else
    echo "==> ADMIN_GITHUB_USER not set — skipping SSH key import."
  fi
else
  echo "==> ADMIN_USERNAME not set — skipping admin user creation."
fi

echo "==> Zeroing free space for better template compression..."
dd if=/dev/zero of=/tmp/zero.fill bs=4M || true
rm -f /tmp/zero.fill
sync

echo "==> setup.sh complete."

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

echo "==> Cleaning up package cache..."
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

# Install a oneshot systemd service to regenerate SSH host keys on the first boot
# after a VM is cloned from this template.
#
# WHY NOT rely on ssh-keygen@.service:
#   ssh-keygen@.service is Wanted= by ssh.service (the persistent daemon).
#   On Ubuntu 22.04+ with socket activation, ssh.service is never started —
#   ssh.socket listens on :22 and spawns per-connection ssh@.service instances.
#   Because ssh.service is not running, ssh-keygen@.service is never triggered,
#   and cloned VMs have no host keys → sshd refuses all connections.
#
# This oneshot service runs before ssh.socket AND ssh.service, covers both
# socket-activated and traditional sshd configurations, and disables itself
# after the first successful run so subsequent boots are unaffected.
echo "==> Installing SSH host key regeneration service for cloned VMs..."
cat > /etc/systemd/system/ssh-host-keygen.service << 'UNIT'
[Unit]
Description=Regenerate SSH host keys on first boot after cloning
DefaultDependencies=no
Before=ssh.socket ssh.service sshd.service network.target
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=/bin/systemctl disable ssh-host-keygen.service

[Install]
WantedBy=sysinit.target
UNIT
systemctl enable ssh-host-keygen.service

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
    echo "==> Importing SSH keys from GitHub for ${ADMIN_GITHUB_USER}..."
    sudo -u "${ADMIN_USERNAME}" ssh-import-id-gh "${ADMIN_GITHUB_USER}"
  else
    echo "==> ADMIN_GITHUB_USER not set — skipping SSH key import."
  fi
else
  echo "==> ADMIN_USERNAME not set — skipping admin user creation."
fi

echo "==> Clearing machine-id so each clone gets a unique ID on first boot..."
# The Packer build copied the live-installer's machine-id into the installed
# OS (via late-commands) to ensure the installed OS gets the same DHCP lease
# as the live installer — critical for Packer's SSH connection after reboot.
# Now that provisioning is complete, truncate machine-id so systemd generates
# a fresh unique ID when each clone boots, preventing DHCP collisions.
truncate -s 0 /etc/machine-id

echo "==> Zeroing free space for better template compression..."
# Write to /var/tmp, NOT /tmp. On Ubuntu /tmp is mounted as tmpfs by systemd
# (tmp.mount), so writing zeros there fills RAM and never touches the disk —
# making this step a no-op for thin-provisioned template compaction.
# /var/tmp lives on the root filesystem on Ubuntu defaults, so the zeroes
# actually land on the OS disk that Packer is about to convert to a template.
dd if=/dev/zero of=/var/tmp/zero.fill bs=4M || true
rm -f /var/tmp/zero.fill
sync

echo "==> setup.sh complete."

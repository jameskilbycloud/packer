#!/usr/bin/env bash
# =============================================================================
# desktop.sh — Desktop-specific package installation
# Runs inside the VM during the Packer build via shell provisioner, after
# setup.sh. Installs desktop packages here rather than via autoinstall
# packages: because their postinst scripts (GDM3/X session hooks, snapd
# seeding) deadlock in subiquity's headless chroot. Installing on a
# fully-booted system avoids this entirely.
# =============================================================================
set -euo pipefail

echo "==> Waiting for apt lock to be released..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 2
done

# setup.sh cleans /var/lib/apt/lists/* at the end — refresh before installing.
echo "==> Updating package index..."
apt-get update -y

echo "==> Installing desktop packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ubuntu-desktop-minimal \
  open-vm-tools-desktop

# Hold snap auto-refresh for 60 days so it does not race with the remaining
# Packer provisioners (vmtools.sh). This runs on the fully-booted system where
# snapd is available — it cannot be done in autoinstall late-commands because
# snapd is not installed until this script runs.
echo "==> Holding snap auto-refresh for 60 days..."
snap set system refresh.hold="$(date -u -d '+60 days' '+%Y-%m-%dT%H:%M:%S+00:00')" || true

echo "==> desktop.sh complete."

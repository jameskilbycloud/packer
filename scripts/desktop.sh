#!/usr/bin/env bash
# =============================================================================
# desktop.sh — Desktop-specific package installation
# Runs inside the VM during the Packer build via shell provisioner, after
# setup.sh. Installs ubuntu-desktop-minimal here rather than via autoinstall
# packages: because its postinst scripts (snapd seeding, GDM3 D-Bus init)
# hang the subiquity installer in a headless chroot environment. Installing
# on a fully-booted system avoids this entirely.
# =============================================================================
set -euo pipefail

echo "==> Waiting for apt lock to be released..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 2
done

echo "==> Installing ubuntu-desktop-minimal..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ubuntu-desktop-minimal

echo "==> Disabling snapd auto-refresh (template should not auto-update)..."
snap set system refresh.hold="$(date --date='today + 60 days' +%Y-%m-%dT%H:%M:%S+00:00)" 2>/dev/null || true

echo "==> desktop.sh complete."

#!/usr/bin/env bash
# =============================================================================
# vmtools.sh — Verify and configure open-vm-tools
# Runs inside the VM during the Packer build via shell provisioner.
# =============================================================================
set -euo pipefail

echo "==> Checking open-vm-tools installation..."

# Wait for apt lock
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 2
done

# Install open-vm-tools if not already present (autoinstall should have done this)
if ! dpkg -l open-vm-tools 2>/dev/null | grep -q '^ii'; then
  echo "==> open-vm-tools not found — installing..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y open-vm-tools
else
  echo "==> open-vm-tools is already installed."
fi

# Install desktop variant if GNOME/GDM is present
if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
  if ! dpkg -l open-vm-tools-desktop 2>/dev/null | grep -q '^ii'; then
    echo "==> Desktop environment detected — installing open-vm-tools-desktop..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y open-vm-tools-desktop
  else
    echo "==> open-vm-tools-desktop is already installed."
  fi
fi

echo "==> Enabling and starting open-vm-tools service..."
systemctl enable open-vm-tools || true
systemctl start open-vm-tools || true

echo "==> Verifying vmtoolsd is running..."
if systemctl is-active --quiet open-vm-tools; then
  echo "==> open-vm-tools is active."
else
  echo "WARNING: open-vm-tools service is not active — check journalctl -u open-vm-tools"
fi

echo "==> VMware tools version info:"
vmware-toolbox-cmd --version 2>/dev/null || vmtoolsd --version 2>/dev/null || echo "(version check unavailable)"

echo "==> vmtools.sh complete."

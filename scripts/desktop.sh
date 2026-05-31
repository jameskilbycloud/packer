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

# ── Clone-friendly netplan rewrite ────────────────────────────────────────────
# On 24.04 desktop, netplan + NetworkManager translate `match: driver: vmxnet3`
# (from the autoinstall network block) into an NM keyfile with the install-time
# MAC baked in by NM's `connection.mac-address` field. When the template is
# cloned, ens33 gets a fresh MAC, NM can't find a matching keyfile, reports
# the device as "unmanaged", and the link stays DOWN forever. Confirmed by
# the user-mode diag from run 26686255321:
#   ens33  ethernet  unmanaged  --
#   [nmcli connection show]            (empty — no profiles)
#
# Replace the persisted netplan with two clone-friendly properties:
#   • renderer: NetworkManager — explicit; desktop default, removes ambiguity
#     with systemd-networkd which is also wanted at multi-user.target.
#   • match: name: "en*"       — match by predictable kernel name. Name is
#     hardware-version-stable on VMware (still ens33 / ens160 after clone),
#     so the resulting NM keyfile survives the MAC change.
#
# Why here, not in autoinstall late-commands:
#   The same regression pattern as the diag-group add — late-commands running
#   in subiquity have a kill-the-rest failure mode that broke 2204 + 2604 in
#   commit 3be3b8d. desktop.sh runs over an established SSH connection where
#   failure is bounded and visible.
#
# Why not run `netplan apply`:
#   The build VM is currently networked. Re-applying could disconnect Packer.
#   `netplan generate` is a static config check — it only re-renders the
#   backend config files in /run/* (tmpfs) without re-activating links.
#   On the clone's first boot, netplan generate runs again from scratch and
#   the new YAML takes effect cleanly.
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
if [[ -f "${NETPLAN_FILE}" ]]; then
  echo "==> Rewriting ${NETPLAN_FILE} for clone-safe NM + name-based match..."
  # Back up the subiquity-written original for forensics — the goss
  # validator can assert presence of the new file but the original is
  # useful when debugging why the rewrite was needed.
  cp -a "${NETPLAN_FILE}" "${NETPLAN_FILE}.subiquity-original"
  cat > "${NETPLAN_FILE}" <<'NETPLAN'
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    primary:
      match:
        name: "en*"
      dhcp4: true
NETPLAN
  chmod 600 "${NETPLAN_FILE}"
  echo "==> Validating new netplan via 'netplan generate'..."
  if netplan generate 2>&1; then
    echo "    ✔ netplan generate succeeded — config is well-formed"
  else
    echo "    ✘ netplan generate FAILED — rolling back to original"
    mv "${NETPLAN_FILE}.subiquity-original" "${NETPLAN_FILE}"
    exit 1
  fi
else
  echo "==> ${NETPLAN_FILE} not found — skipping clone-safe rewrite."
  echo "    (Expected on every Ubuntu desktop autoinstall; investigate if missing.)"
fi

echo "==> desktop.sh complete."

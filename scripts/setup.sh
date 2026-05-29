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
# Ordering note: the earlier version used DefaultDependencies=no +
# WantedBy=sysinit.target, which fired before systemd-remount-fs.service
# remounted / read-write. ssh-keygen then printed "Read-only file system"
# for every key type, exited 0 (it doesn't propagate per-key write failures),
# ExecStartPost happily disabled the unit, and the clone booted with NO host
# keys → sshd refused all connections forever. Default deps + ordering
# against ssh.socket/ssh.service is the right pattern: it runs in late
# boot when / is writable, but still before sshd tries to start.
#
# /usr/bin/sh wrapper: ssh-keygen -A silently no-ops failures across key
# types, so we add an explicit post-check; if any key is still missing
# after the run we propagate a non-zero exit so ExecStartPost (and the
# disable) do NOT run, and the unit remains enabled to retry on next boot.
cat > /etc/systemd/system/ssh-host-keygen.service << 'UNIT'
[Unit]
Description=Regenerate SSH host keys on first boot after cloning
# DefaultDependencies=no breaks a systemd ordering cycle that surfaces on
# 24.04+ where ssh is socket-activated by default. With the default deps,
# systemd adds implicit After=basic.target / sysinit.target. The cycle is:
#   basic.target -> sockets.target -> ssh.socket -> ssh-host-keygen.service
#   ssh-host-keygen.service -> basic.target (the implicit After we want gone)
# systemd "fixes" the cycle by deleting sockets.target/start, which leaves
# ssh.socket half-started and ssh.service never gets enabled — port 22 stays
# closed forever. Confirmed by run 26621101768's 2604-server smoke
# diagnostic dump:
#   ssh.service:  is-active=inactive is-enabled=disabled
#   ssh.socket:   is-active=active   is-enabled=enabled
#   journal: "basic.target: Found ordering cycle: ... after sockets.target"
#   journal: "basic.target: Job sockets.target/start deleted to break ..."
# 22.04 doesn't hit this because it uses ssh.service directly (not socket-
# activated by default), so the cycle path through sockets.target doesn't
# form. With DefaultDependencies=no we explicitly state every After/Before/
# Conflicts we want — local-fs.target gives us a writable /etc, shutdown
# ordering handled below.
DefaultDependencies=no
After=systemd-remount-fs.service local-fs.target
Before=ssh.socket ssh.service sshd.service shutdown.target
Conflicts=shutdown.target
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/bin/ssh-keygen -A && test -s /etc/ssh/ssh_host_rsa_key && test -s /etc/ssh/ssh_host_ed25519_key'
ExecStartPost=/bin/systemctl disable ssh-host-keygen.service
RemainAfterExit=yes

[Install]
WantedBy=ssh.socket ssh.service
UNIT
systemctl enable ssh-host-keygen.service

echo "==> Installing first-boot hostname uniquification service for cloned VMs..."
# The autoinstall sets the hostname to the build target name (e.g.
# `ubuntu-2604-server`). Without intervention, every clone of the template
# boots with that same hostname → DNS / monitoring / Slack collisions on
# any shared network. Cloud-init is intentionally neutralised on this
# stack (datasource_list: [None]) so we cannot rely on its set_hostname
# module — instead, install a oneshot systemd unit that runs once on the
# first boot of each clone and appends a 6-hex-char suffix derived from
# the vSphere VM UUID.
#
# Why the VM UUID:
#   - Always present on vSphere VMs (DMI table, /sys/class/dmi/id/product_uuid).
#   - vSphere assigns a fresh UUID per clone by default → unique per clone.
#   - Stable across reboots of the same VM → same VM always gets the same
#     hostname (idempotent).
#   - No external dependency (no DHCP option 12, no guestinfo, no random).
mkdir -p /usr/local/sbin /var/lib/packer-firstboot
cat > /usr/local/sbin/firstboot-hostname.sh << 'SCRIPT'
#!/bin/bash
# Append a 6-hex-char suffix derived from the vSphere VM UUID to the
# template's hostname so cloned VMs do not collide on a shared network.
# Runs once on the first boot of each clone, gated by the systemd unit's
# ConditionPathExists guard.
set -euo pipefail

# Read /etc/hostname directly instead of `hostnamectl --static`. hostnamectl
# is a D-Bus client and this unit fires before network.target / dbus is
# guaranteed up at that early-boot point. The previous version exited
# non-zero at this line on every clone, `set -e` aborted before the
# sentinel touch + ExecStartPost=disable, and the unit stayed enabled
# forever with no clone ever getting a unique hostname.
current=$(cat /etc/hostname 2>/dev/null || hostname -s 2>/dev/null || echo "ubuntu")
current="${current// /}"  # trim any whitespace
uuid_file="/sys/class/dmi/id/product_uuid"

if [[ ! -r "${uuid_file}" ]]; then
  echo "firstboot-hostname: ${uuid_file} not readable; leaving hostname as ${current}" >&2
  touch /var/lib/packer-firstboot/hostname.done
  exit 0
fi

uuid=$(tr -d -- '-\n' < "${uuid_file}" | tr 'A-Z' 'a-z')
suffix="${uuid: -6}"

if [[ -z "${suffix}" || ${#suffix} -lt 6 ]]; then
  echo "firstboot-hostname: empty/short suffix from ${uuid_file}; leaving hostname as ${current}" >&2
  touch /var/lib/packer-firstboot/hostname.done
  exit 0
fi

new="${current}-${suffix}"
if [[ "${current}" == "${new}" ]]; then
  echo "firstboot-hostname: hostname already '${new}', nothing to do"
  touch /var/lib/packer-firstboot/hostname.done
  exit 0
fi

echo "firstboot-hostname: ${current} -> ${new}"
# Write /etc/hostname directly and update the running kernel hostname with
# the `hostname` syscall, both of which work without D-Bus / systemd-hostnamed.
# Equivalent to `hostnamectl set-hostname` end-state-wise: /etc/hostname is
# the source of truth at next boot, and `hostname` sets the live value now.
echo "${new}" > /etc/hostname
hostname "${new}"

# Update /etc/hosts so loopback resolution matches the new hostname.
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new}/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "${new}" >> /etc/hosts
fi

touch /var/lib/packer-firstboot/hostname.done
SCRIPT
chmod +x /usr/local/sbin/firstboot-hostname.sh

# Mirror the ssh-host-keygen.service pattern: oneshot, gated by a sentinel
# path, disables itself after success.
#
# Same ordering bug as ssh-host-keygen — the previous version was
# DefaultDependencies=no + Before=sysinit.target, which fired before /
# was remounted read-write. The script's hostnamectl + /etc/hosts edit +
# `touch /var/lib/packer-firstboot/hostname.done` all failed silently;
# the unit exited 1 and stayed enabled (no ExecStartPost on failure),
# but no clone ever got the suffix. Using default deps + ordering
# against network-pre.target gets us a writable root and still runs
# before NetworkManager / systemd-networkd sends DHCP with a hostname.
cat > /etc/systemd/system/firstboot-hostname.service << 'UNIT'
[Unit]
Description=Append a unique suffix to the hostname on first boot of each clone
After=systemd-remount-fs.service local-fs.target
Before=network-pre.target network.target NetworkManager.service systemd-networkd.service
ConditionPathExists=!/var/lib/packer-firstboot/hostname.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-hostname.sh
ExecStartPost=/bin/systemctl disable firstboot-hostname.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable firstboot-hostname.service

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
    admin_home=$(getent passwd "${ADMIN_USERNAME}" | cut -d: -f6)
    ssh_dir="${admin_home}/.ssh"
    auth_keys="${ssh_dir}/authorized_keys"

    # -H forces HOME to ${ADMIN_USERNAME}'s home so ssh-import-id's
    # os.path.expanduser("~") always lands on the right authorized_keys,
    # regardless of sudoers defaults. (env_reset usually does this for us,
    # but being explicit removes the dependency.)
    sudo -H -u "${ADMIN_USERNAME}" ssh-import-id-gh "${ADMIN_GITHUB_USER}"

    # Fail loudly if no key actually made it onto disk. The build log will
    # otherwise show a happy "[1] SSH keys [Authorized]" while sshd rejects
    # every login attempt because the file isn't where sshd expects it.
    if [[ ! -s "${auth_keys}" ]]; then
      echo "ERROR: ssh-import-id-gh reported success but ${auth_keys} is missing/empty" >&2
      exit 1
    fi

    # Enforce the perms sshd requires under StrictModes (the default).
    # ssh-import-id usually gets these right, but it has historically left
    # behind a root-owned ~/.ssh on some sudo configurations — explicit
    # chown/chmod here makes the outcome deterministic.
    chown -R "${ADMIN_USERNAME}:${ADMIN_USERNAME}" "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    chmod 600 "${auth_keys}"
    echo "==> Authorized $(wc -l < "${auth_keys}") key(s) for ${ADMIN_USERNAME} at ${auth_keys}"
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

echo "==> Capturing build metadata for forensics..."
# Snapshot of what's installed at template-build time. Lives inside the
# produced template, so any clone can be inspected post-deploy:
#   cat /var/log/packer-build-info.json
#   diff <(dpkg -l) /var/log/packer-package-list.txt   # drift since build
#
# package_list_sha256 lets you assert "the package set is identical to last
# week's build" by comparing the hash, without diffing 200 KB of dpkg output.
#
# After writing the file we ALSO emit it to stdout between sentinel markers.
# The CI workflow's "Capture build metrics" step greps the Packer log for
# these markers and embeds the JSON in build-metrics-<label>-<run>.json,
# so the workflow artefact carries provenance about what was actually
# installed at build time without anyone having to ssh into a clone.
mkdir -p /var/log

# Full dpkg snapshot first — the JSON references its hash.
dpkg -l > /var/log/packer-package-list.txt 2>/dev/null || true

python3 - <<'PY' > /var/log/packer-build-info.json
import datetime
import hashlib
import json
import subprocess

pretty = ""
with open("/etc/os-release") as f:
    for line in f:
        if line.startswith("PRETTY_NAME="):
            pretty = line.split("=", 1)[1].strip().strip('"')
            break

try:
    out = subprocess.check_output(
        ["dpkg", "-l"], stderr=subprocess.DEVNULL
    ).decode()
    pkg_count = sum(1 for line in out.splitlines() if line.startswith("ii "))
except Exception:
    pkg_count = 0

try:
    with open("/var/log/packer-package-list.txt", "rb") as f:
        pkg_sha256 = hashlib.sha256(f.read()).hexdigest()
except Exception:
    pkg_sha256 = ""

print(json.dumps({
    "kernel_version": subprocess.check_output(["uname", "-r"]).decode().strip(),
    "os_pretty_name": pretty,
    "package_count": pkg_count,
    "package_list_sha256": pkg_sha256,
    "captured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PY

# Emit to stdout between sentinel markers so the CI metrics step can extract
# the JSON from the Packer log without needing a separate file-download
# provisioner. The markers MUST appear on lines by themselves.
echo "==> PACKER_BUILD_INFO_BEGIN"
cat /var/log/packer-build-info.json
echo "==> PACKER_BUILD_INFO_END"

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

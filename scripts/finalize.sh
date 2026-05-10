#!/usr/bin/env bash
# =============================================================================
# finalize.sh — Strip build-only security knobs before template conversion.
#
# Runs as a provisioner step BEFORE goss-validate.sh so the goss spec can
# assert the post-finalize state — i.e. exactly what clones see. After this
# script the only remaining Packer step is `shutdown_command`.
#
# What's removed:
#   /etc/sudoers.d/90-packer-${BUILD_USERNAME}
#     The NOPASSWD entry granted by autoinstall late-commands. Without it,
#     `sudo` on a clone prompts for the build user's password (which is
#     still set, via build_password_encrypted) — exactly what an
#     unprivileged workstation user would expect.
#
#   /etc/ssh/sshd_config.d/10-packer-pwauth.conf
#     The drop-in that overrides Ubuntu's default
#     `PasswordAuthentication no`. Removing it lets the distro default
#     win again, so cloned VMs accept SSH only via public-key auth (which
#     consumers should set up via cloud-init alternatives, ssh-import-id,
#     or whatever their config-management tool provides).
#
# What's NOT changed:
#   The build user, the user's password, SSH host keys (already wiped;
#   regenerated on first boot), the build-info JSON snapshots in /var/log,
#   and the UFW mask. UFW remains masked because re-enabling it
#   pre-clone risks blocking SSH on the first boot of fresh clones; that
#   policy is the responsibility of post-clone configuration management.
#
# What about shutdown_command:
#   The source block's shutdown_command is
#     `echo '${var.build_password}' | sudo -S shutdown -P now`
#   It still works after finalize: removing the NOPASSWD entry doesn't
#   delete the user's password, and `sudo -S` reads the password from
#   stdin. So the shutdown step has no dependency on the knobs we just
#   removed.
# =============================================================================
set -euo pipefail

BUILD_USERNAME="${BUILD_USERNAME:?BUILD_USERNAME must be set}"

sudoers_file="/etc/sudoers.d/90-packer-${BUILD_USERNAME}"
pwauth_file="/etc/ssh/sshd_config.d/10-packer-pwauth.conf"

echo "==> Removing passwordless sudo entry: ${sudoers_file}"
rm -f "${sudoers_file}"

echo "==> Removing SSH PasswordAuthentication build-time drop-in: ${pwauth_file}"
rm -f "${pwauth_file}"

# We are only DELETING drop-in files, not editing sshd_config — there is no
# syntax to break, so a parse-test isn't needed. Calling `sshd -t` here also
# fails the build because setup.sh already wiped /etc/ssh/ssh_host_*: sshd
# refuses to validate without host keys present ("sshd: no hostkeys
# available -- exiting"), which is the desired template state because
# ssh-host-keygen.service regenerates them on first boot of each clone.
# So no verification step here.

echo "==> finalize.sh complete. Template will convert with build-only knobs removed."

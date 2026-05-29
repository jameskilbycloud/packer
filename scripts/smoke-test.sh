#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh
# Post-publish smoke test for a Packer-built template.
#
# Clones the newest template matching TEMPLATE_PATTERN, powers it on, waits
# for VMware Tools to report an IP, injects a fresh ephemeral pubkey via the
# VMware Tools Guest Operations API (the template has SSH password auth
# disabled by finalize.sh, so a direct SSH password login is not an option),
# SSHes in, runs goss-validate.sh against the spec under sudo, and destroys
# the clone in an EXIT trap regardless of pass / fail.
#
# Why a separate post-publish smoke test:
# The build-time goss pass runs BEFORE Packer converts the VM to a template,
# so it cannot catch regressions that only manifest on the cloned, first-boot
# template VM — e.g. first-boot oneshot ordering (ssh-host-keygen.service
# vs rootfs-rw), cloud-init neutralisation regressions, open-vm-tools service
# not actually surviving the template conversion, etc. This script exercises
# exactly the boot path a deployed clone will hit.
#
# Required env:
#   GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_DATACENTER
#   TEMPLATE_PATTERN  — glob to find the newest template (e.g. "ubuntu-2404-server-*")
#   GOSS_SPEC         — local path to goss spec (goss/server.yaml or goss/desktop.yaml)
#   BUILD_USERNAME    — guest OS user (must match the autoinstall user)
#   BUILD_PASSWORD    — guest OS password (used for VMware Tools guest auth + sudo)
#
# Optional env:
#   GOVC_INSECURE          — default "false"
#   VSPHERE_FOLDER         — where to clone (default: "packer")
#   VSPHERE_CLUSTER        — cluster for resource pool
#   VSPHERE_HOST           — ESXi host (alternative to cluster)
#   VSPHERE_DATASTORE      — datastore for the clone
#   SMOKE_TIMEOUT_SECONDS  — total wait for VMware Tools IP (default 600)
#   SSH_TIMEOUT_SECONDS    — wait for SSH after IP appears (default 180)
#   CLONE_NAME             — override generated clone name
# =============================================================================
set -euo pipefail

: "${GOVC_URL:?}"
: "${GOVC_USERNAME:?}"
: "${GOVC_PASSWORD:?}"
: "${GOVC_DATACENTER:?}"
: "${TEMPLATE_PATTERN:?Set TEMPLATE_PATTERN to a glob matching the template, e.g. ubuntu-2404-server-*}"
: "${GOSS_SPEC:?Set GOSS_SPEC to the goss spec file path}"
: "${BUILD_USERNAME:?Set BUILD_USERNAME (must match the guest user)}"
: "${BUILD_PASSWORD:?Set BUILD_PASSWORD (guest user password)}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER
export GOVC_INSECURE="${GOVC_INSECURE:-false}"

VSPHERE_FOLDER="${VSPHERE_FOLDER:-packer}"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-600}"
SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-240}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOSS_SPEC_ABS="$(cd "$(dirname "${GOSS_SPEC}")" && pwd)/$(basename "${GOSS_SPEC}")"
GOSS_VALIDATE_SCRIPT="${REPO_ROOT}/scripts/goss-validate.sh"

[[ -f "${GOSS_SPEC_ABS}" ]] || { echo "❌ goss spec not found: ${GOSS_SPEC_ABS}"; exit 1; }
[[ -f "${GOSS_VALIDATE_SCRIPT}" ]] || { echo "❌ goss-validate.sh not found: ${GOSS_VALIDATE_SCRIPT}"; exit 1; }

# ── Locate template ───────────────────────────────────────────────────────────
# Detection uses `govc object.collect -s <path> config.template`, which returns
# the property value as a single line of plain text ("true" / "false") — no
# JSON to parse and no version-specific schema concerns. The previous
# implementation parsed `govc vm.info -json` output and broke after govc
# changed its JSON shape (capitalisation + nesting), silently classifying
# real templates as non-templates.
echo "==> Locating newest template matching '${TEMPLATE_PATTERN}'..."
matches=$(govc find . -type m -name "${TEMPLATE_PATTERN}" 2>/dev/null || true)
if [[ -z "${matches}" ]]; then
  echo "❌ No VMs match ${TEMPLATE_PATTERN}. Build likely didn't produce a"
  echo "   template — check the upstream build job."
  exit 1
fi

template=""
# Sort matches newest-first (YYYYMMDD date suffix is zero-padded so lex-desc
# is newest-first) and pick the first one that's actually a template.
declare -A diag_states
while IFS= read -r p; do
  [[ -z "${p}" ]] && continue
  is_tpl=$(govc object.collect -s "${p}" config.template 2>/dev/null || echo "(unknown)")
  diag_states["${p}"]="${is_tpl}"
  if [[ "${is_tpl}" == "true" && -z "${template}" ]]; then
    template="${p}"
  fi
done < <(printf '%s\n' "${matches}" | sed '/^$/d' | sort -r)

if [[ -z "${template}" ]]; then
  echo "❌ No template (config.template=true) found among matches:"
  for p in "${!diag_states[@]}"; do
    echo "    ${p}  →  config.template=${diag_states[$p]}"
  done
  echo ""
  echo "    If every match is config.template=false, the build job did not"
  echo "    convert to template. Common cause: a build that's still in flight"
  echo "    or one that failed before Packer's final convert step. Wait for"
  echo "    the build to finish or destroy the orphaned VMs, then retry."
  exit 1
fi
echo "    template: ${template}"

# ── Clone name + EXIT cleanup trap ────────────────────────────────────────────
CLONE_NAME="${CLONE_NAME:-smoke-$(basename "${template}")-${GITHUB_RUN_ID:-$(date +%s)}}"
echo "==> Clone target: ${CLONE_NAME}"

# Define guest_auth up-front so the EXIT-trap cleanup can attempt guest.run-
# based diagnostics on ANY non-zero exit — including "Clone did not report
# an IP within Ns" failures (where the script bails before reaching the
# pubkey injection that originally set guest_auth). VMware Tools' Guest
# Operations API rides on the hypervisor RPC channel, not the guest's
# network, so guest.run still works on a clone that has no IP — as long as
# vmtoolsd is alive inside the guest. For 2404-desktop clones that boot to
# GDM but never get a DHCP lease, this gives us the only diagnostic path
# we have for what NetworkManager / netplan / systemd-networkd actually
# did at boot.
guest_auth=(-l "${BUILD_USERNAME}:${BUILD_PASSWORD}" -vm "${CLONE_NAME}")

cleanup() {
  # Accept exit code as $1 if the trap forwarded one (e.g. from a multi-
  # command trap body where `$?` would otherwise be clobbered by the
  # previous command in the trap). Fall back to `$?` for the simple
  # `trap cleanup EXIT` form.
  local rc=${1:-$?}
  # On any non-zero exit, dump systemd / journal state from the live clone
  # before we destroy it. Uses guest.run rather than SSH because guest.run
  # works even when sshd is broken — which is exactly when we need the
  # diagnostic most. If guest.run itself fails (e.g. the clone never
  # booted far enough for VMware Tools), the dump is a no-op.
  if [[ ${rc} -ne 0 && -n "${guest_auth:-}" ]]; then
    echo ""
    echo "==> Smoke failed (rc=${rc}). Diagnostic dump from the clone via VMware Tools:"
    # Write the diagnostic script to a local temp file, upload it to the
    # guest, then invoke /bin/sh against the uploaded path. We do NOT pass
    # the script body inline via `sh -c "<multi-line>"` because vmtoolsd's
    # Guest Operations API does not preserve newlines in the arguments
    # parameter — only the first line of a multi-line `-c` script survives.
    # That bug is what produced run 26570996931's "rc=0, bytes=0" empty
    # diagnostic.
    local diag_local diag_guest diag_output diag_rc=0
    diag_local=$(mktemp)
    diag_guest="/tmp/smoke-diag-${GITHUB_RUN_ID:-$$}.sh"
    cat > "${diag_local}" <<'DIAG'
#!/bin/sh
set +e
echo "--- hostname (live + /etc/hostname) ---"
hostname
cat /etc/hostname 2>&1
echo
echo "--- systemctl get-default ---"
systemctl get-default 2>&1
echo
echo "--- systemctl is-system-running ---"
systemctl is-system-running --wait=false 2>&1 | head -3
echo
echo "--- first-boot service states ---"
for u in ssh.service ssh.socket sshd.service ssh-host-keygen.service firstboot-hostname.service; do
  printf "%-40s  " "$u"
  echo "is-active=$(systemctl is-active "$u" 2>&1) is-enabled=$(systemctl is-enabled "$u" 2>&1)"
done
echo
echo "--- systemctl list-unit-files (first-boot units) ---"
systemctl list-unit-files firstboot-hostname.service ssh-host-keygen.service --no-pager 2>&1 | head -10
echo
echo "--- multi-user.target wants symlinks (first-boot) ---"
ls -la /etc/systemd/system/multi-user.target.wants/ 2>&1 | grep -E "firstboot|ssh-host-keygen" | head -10
echo "(full multi-user.target.wants listing:)"
ls /etc/systemd/system/multi-user.target.wants/ 2>&1 | head -50
echo
echo "--- systemctl show firstboot-hostname.service (key props) ---"
systemctl show firstboot-hostname.service \
  --property=Id,LoadState,ActiveState,SubState,UnitFileState,WantedBy,RequiredBy,ConditionResult,AssertResult,Before,After,DefaultDependencies,LoadError \
  2>&1 | head -20
echo
echo "--- /var/lib/packer-firstboot/ ---"
ls -la /var/lib/packer-firstboot/ 2>&1 | head -10
echo
echo "--- /usr/local/sbin/firstboot-hostname.sh (first 30 lines) ---"
head -30 /usr/local/sbin/firstboot-hostname.sh 2>&1
echo
echo "--- ip link show ---"
ip -brief link show 2>&1 | head -10
echo
echo "--- ip addr show ---"
ip -brief addr show 2>&1 | head -10
echo
echo "--- ip route ---"
ip -brief route show 2>&1 | head -10
echo
echo "--- listening TCP sockets (ss -lntp) ---"
ss -lntp 2>&1 | head -20
echo
echo "--- nftables ruleset ---"
nft list ruleset 2>&1 | head -30 || echo "(nft not available or rules empty)"
echo
echo "--- iptables-legacy (fallback) ---"
iptables -L -n 2>&1 | head -10 || echo "(iptables-legacy not available)"
echo
echo "--- /etc/netplan/ ---"
ls -la /etc/netplan/ 2>&1
for f in /etc/netplan/*.yaml; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  cat "$f" 2>&1
done
echo
echo "--- NetworkManager state (if installed) ---"
if command -v nmcli >/dev/null 2>&1; then
  echo "[nmcli general]"
  nmcli general 2>&1
  echo "[nmcli connection show]"
  nmcli connection show 2>&1
  echo "[nmcli device status]"
  nmcli device status 2>&1
else
  echo "(nmcli not installed)"
fi
echo
echo "--- systemd-networkd state (if active) ---"
if systemctl is-active systemd-networkd >/dev/null 2>&1; then
  networkctl status --no-pager 2>&1 | head -40
else
  echo "(systemd-networkd not active)"
fi
echo
echo "--- journalctl: NetworkManager (full) ---"
journalctl -u NetworkManager --no-pager 2>&1 | tail -40
echo
echo "--- journalctl: systemd-networkd (full) ---"
journalctl -u systemd-networkd --no-pager 2>&1 | tail -30
echo
echo "--- journalctl: cloud-init (full) ---"
journalctl -u 'cloud-init*' --no-pager 2>&1 | tail -30
echo
echo "--- journalctl: firstboot-hostname (full) ---"
journalctl -u firstboot-hostname --no-pager 2>&1 | tail -50
echo
echo "--- journalctl: ssh-host-keygen (full) ---"
journalctl -u ssh-host-keygen --no-pager 2>&1 | tail -30
echo
echo "--- journalctl: ssh.service (full) ---"
journalctl -u ssh.service --no-pager 2>&1 | tail -30
echo
echo "--- journalctl: ssh.socket (full) ---"
journalctl -u ssh.socket --no-pager 2>&1 | tail -30
echo
echo "--- journalctl: this boot, ordering-cycle / dependency-related ---"
journalctl -b --no-pager 2>&1 | grep -iE "ordering cycle|deleted to break|firstboot-hostname|dependency failed|cannot bind|Address already in use" | head -30
echo
echo "--- systemctl --failed ---"
systemctl --failed --no-pager 2>&1 | head -30
DIAG
    govc guest.upload -f "${guest_auth[@]}" "${diag_local}" "${diag_guest}" 2>&1 \
      | sed "s/^/   [upload] /" || echo "   (diag upload failed)"
    # Run the diag script under sudo on the guest. govc guest.run authenticates
    # as the BUILD_USERNAME user (not root) — and without root, `ss -lntp`
    # truncates, `journalctl -u <unit>` returns empty for system units, and
    # `nft list ruleset` / `iptables -L` fail with "Permission denied". finalize.sh
    # removes the NOPASSWD sudoers drop-in, so we have to provide the password
    # via stdin. -e BUILD_PASS=... passes the password through guest.run's env;
    # `echo "$BUILD_PASS" | sudo -S /bin/sh diag.sh` then runs the entire diag
    # under root in a single guest.run call.
    diag_output=$(govc guest.run "${guest_auth[@]}" \
      -e "BUILD_PASS=${BUILD_PASSWORD}" -- \
      /bin/sh -c "echo \"\$BUILD_PASS\" | sudo -S /bin/sh ${diag_guest} 2>&1" 2>&1) || diag_rc=$?
    rm -f "${diag_local}"
    echo "--- govc guest.run rc=${diag_rc}, output bytes=${#diag_output} ---"
    if [[ -n "${diag_output}" ]]; then
      printf '%s\n' "${diag_output}" | sed "s/^/   /"
    else
      echo "   (no output — auth/comms failure, or the diag script itself returned nothing)"
    fi
    echo "--- end diagnostic dump ---"
    echo ""
  fi

  # vCenter-side state via govc — works even when both VMware Tools (no
  # guest.run) AND the framebuffer (no screenshot) are unavailable, because
  # vm.info + events go through the vSphere SDK directly. Always-available
  # diagnostic of last resort.
  if [[ ${rc} -ne 0 ]]; then
    echo ""
    echo "==> vCenter-side VM state (govc vm.info):"
    govc vm.info -r "${CLONE_NAME}" 2>&1 | sed 's/^/   /' | head -40 \
      || echo "   (vm.info failed)"
    echo ""
    echo "==> VMware Tools state (govc object.collect):"
    # Direct property fetch — covers the "Tools claims running but no IP
    # reported" case (e.g. 2404-desktop clones that sit at the GDM login
    # screen with no DHCP lease). Tells us whether vmtoolsd is even
    # communicating with the host, separate from whether the guest has a
    # working IP.
    for prop in guest.toolsStatus guest.toolsRunningStatus guest.toolsVersionStatus2 guest.hostName guest.ipAddress guest.guestState; do
      val=$(govc object.collect -s "${CLONE_NAME}" "${prop}" 2>/dev/null)
      printf "   %-32s  %s\n" "${prop}" "${val:-(empty)}"
    done
    echo ""
    echo "==> Recent vCenter events for the clone (last 20):"
    govc events -n 20 "vm/${CLONE_NAME}" 2>&1 | sed 's/^/   /' | head -25 \
      || echo "   (events failed)"
    echo ""
  fi

  # Console screenshot — works even when VMware Tools / guest.run can't
  # respond (e.g. clone hung at GRUB, kernel panic, never reached userspace).
  # Writes a PNG into ${SMOKE_SCREENSHOT_DIR:-./smoke-screenshots/}, which
  # the workflow's upload-artifact step picks up. Only on failure; success
  # paths skip the screenshot to avoid burning runner I/O.
  if [[ ${rc} -ne 0 ]]; then
    local shot_dir="${SMOKE_SCREENSHOT_DIR:-./smoke-screenshots}"
    mkdir -p "${shot_dir}" 2>/dev/null || true
    local shot_path="${shot_dir}/${CLONE_NAME}.png"
    echo "==> Capturing console screenshot to ${shot_path}..."
    if govc vm.console -capture "${shot_path}" "${CLONE_NAME}" 2>/dev/null; then
      local sz=$(stat -c%s "${shot_path}" 2>/dev/null || stat -f%z "${shot_path}" 2>/dev/null)
      if [[ "${sz}" -lt 1000 ]]; then
        echo "    ⚠ saved ${sz} bytes — likely a 1x1 stub (framebuffer not initialised; VM is stuck pre-video)"
      else
        echo "    ✔ saved ${sz} bytes"
      fi
    else
      echo "    ✘ screenshot failed (VM may have crashed too early, or vSphere refused the WebMKS connection)"
    fi
  fi

  echo "==> EXIT cleanup: destroying ${CLONE_NAME} (rc=${rc})"
  govc vm.power -off=true -force=true "${CLONE_NAME}" 2>/dev/null || true
  govc vm.destroy "${CLONE_NAME}" 2>/dev/null || true
  return ${rc}
}
trap cleanup EXIT

# ── Clone ─────────────────────────────────────────────────────────────────────
clone_args=()
if [[ -n "${VSPHERE_HOST:-}" ]]; then
  clone_args+=(-host "${VSPHERE_HOST}")
elif [[ -n "${VSPHERE_CLUSTER:-}" ]]; then
  clone_args+=(-pool "${VSPHERE_CLUSTER}/Resources")
fi
[[ -n "${VSPHERE_FOLDER:-}" ]] && clone_args+=(-folder "${VSPHERE_FOLDER}")
[[ -n "${VSPHERE_DATASTORE:-}" ]] && clone_args+=(-ds "${VSPHERE_DATASTORE}")

echo "==> Cloning template (powered-off)..."
govc vm.clone -on=false -vm "${template}" "${clone_args[@]}" "${CLONE_NAME}"

echo "==> Powering on clone..."
govc vm.power -on=true "${CLONE_NAME}"

# ── Wait for VMware Tools to report IP ────────────────────────────────────────
echo "==> Waiting up to ${SMOKE_TIMEOUT_SECONDS}s for VMware Tools to report an IP..."
ip=""
deadline=$(( $(date +%s) + SMOKE_TIMEOUT_SECONDS ))
start_epoch=$(date +%s)
midwait_shot_taken=false
while [[ $(date +%s) -lt ${deadline} ]]; do
  ip=$(govc vm.ip -wait=30s "${CLONE_NAME}" 2>/dev/null || true)
  if [[ -n "${ip}" ]]; then
    break
  fi
  # Mid-wait screenshot at the ~50% mark — captures whatever the clone is
  # doing during boot rather than only at the final timeout, where the VM
  # may have entered an uncapturable state (powered-off framebuffer, etc.).
  # Useful for "no IP" failures where Tools never come up but the clone
  # might be sitting at a recoverable boot prompt (cloud-init failure,
  # netplan retry, etc.).
  elapsed=$(( $(date +%s) - start_epoch ))
  if [[ "${midwait_shot_taken}" == "false" && ${elapsed} -gt $(( SMOKE_TIMEOUT_SECONDS / 2 )) ]]; then
    shot_dir="${SMOKE_SCREENSHOT_DIR:-./smoke-screenshots}"
    mkdir -p "${shot_dir}" 2>/dev/null || true
    shot_path="${shot_dir}/${CLONE_NAME}-midwait.png"
    echo "==> Mid-wait screenshot (${elapsed}s in, no IP yet) → ${shot_path}"
    govc vm.console -capture "${shot_path}" "${CLONE_NAME}" 2>/dev/null \
      && echo "    ✔ mid-wait shot saved" \
      || echo "    ✘ mid-wait shot failed"
    midwait_shot_taken=true
  fi
  sleep 5
done
if [[ -z "${ip}" ]]; then
  echo "❌ Clone did not report an IP within ${SMOKE_TIMEOUT_SECONDS}s"
  exit 1
fi
echo "    IP: ${ip}"

# ── Inject ephemeral pubkey via VMware Tools Guest Operations API ─────────────
# The template has SSH password auth disabled (finalize.sh removes the
# build-time drop-in), so we cannot just `sshpass` in. Guest operations
# authenticate against the guest OS via vmtoolsd, bypassing sshd entirely.
echo "==> Injecting ephemeral SSH pubkey via VMware Tools guest ops..."
keydir=$(mktemp -d)
# Capture the script's true exit code as the FIRST thing in the trap body —
# otherwise the preceding `rm` clobbers $? to 0 and cleanup mis-reports
# success on a failed run, silently skipping the diagnostic dump.
#
# shellcheck disable=SC2154
# (_exit_rc is assigned at the start of the same trap string, before it's
# referenced — shellcheck's scope analysis doesn't see the assignment-then-
# use happen inside a single-quoted trap body.)
trap '_exit_rc=$?; rm -rf "${keydir}"; cleanup "${_exit_rc}"' EXIT
ssh-keygen -t ed25519 -N '' -f "${keydir}/id_ed25519" \
  -C "smoke-test-${GITHUB_RUN_ID:-local}" >/dev/null
chmod 600 "${keydir}/id_ed25519"

# guest_auth is already defined above (right after CLONE_NAME), so the EXIT
# trap can use it on early failures. Don't redefine.

# Upload the pubkey to /tmp first — /tmp is world-writable so the upload
# never fails on perms — then a single guest.run shell does the install
# under the build user's identity, so every created file is owned by them
# from birth. We deliberately do NOT `chown` anywhere: govc guest.run
# executes as the authenticated user (no root), and a non-root user on
# Linux cannot chown even to their own UID without CAP_CHOWN, which made
# the previous chown step fail with "Operation not permitted" — silently,
# because govc returns the program's exit code but doesn't surface the
# stderr message to its own stdout.
tmp_pubkey="/tmp/smoke-pubkey-${GITHUB_RUN_ID:-$$}"
govc guest.upload -f "${guest_auth[@]}" \
  "${keydir}/id_ed25519.pub" \
  "${tmp_pubkey}"

govc guest.run "${guest_auth[@]}" -- \
  /bin/sh -c "set -e; \
    mkdir -p /home/${BUILD_USERNAME}/.ssh; \
    chmod 700 /home/${BUILD_USERNAME}/.ssh; \
    mv ${tmp_pubkey} /home/${BUILD_USERNAME}/.ssh/authorized_keys; \
    chmod 600 /home/${BUILD_USERNAME}/.ssh/authorized_keys"

# ── Wait for SSH port ────────────────────────────────────────────────────────
echo "==> Waiting up to ${SSH_TIMEOUT_SECONDS}s for SSH on ${ip}:22..."
ssh_deadline=$(( $(date +%s) + SSH_TIMEOUT_SECONDS ))
ssh_up=false
while [[ $(date +%s) -lt ${ssh_deadline} ]]; do
  if (echo > "/dev/tcp/${ip}/22") 2>/dev/null; then
    ssh_up=true
    break
  fi
  sleep 3
done
if [[ "${ssh_up}" != "true" ]]; then
  echo "❌ SSH on ${ip}:22 not reachable within ${SSH_TIMEOUT_SECONDS}s"
  # EXIT trap will run the diagnostic dump via guest.run before destroying.
  exit 1
fi

# ── Copy goss spec + validate script ──────────────────────────────────────────
SSH_OPTS=(
  -i "${keydir}/id_ed25519"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)

echo "==> Copying goss spec + script via SCP..."
spec_name=$(basename "${GOSS_SPEC_ABS}")
spec_dir=$(dirname "${GOSS_SPEC_ABS}")

# Copy every goss spec file alongside the validator. Specs use gossfile
# includes (e.g. desktop-clone.yaml includes server-clone.yaml), so we send
# the full set rather than tracking the include graph in shell.
scp_files=("${GOSS_VALIDATE_SCRIPT}")
while IFS= read -r f; do
  [[ -n "${f}" ]] && scp_files+=("${f}")
done < <(find "${spec_dir}" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null)

scp "${SSH_OPTS[@]}" "${scp_files[@]}" "${BUILD_USERNAME}@${ip}:/tmp/"

# ── Run goss-validate.sh on the clone, as root ────────────────────────────────
# goss assertions need to read /etc/sudoers.d, /etc/ssh, etc. Use sudo with
# password (finalize.sh removed the NOPASSWD drop-in, but build user is in
# the sudo group via autoinstall).
echo "==> Running goss against the clone (sudo on the guest)..."
ssh "${SSH_OPTS[@]}" "${BUILD_USERNAME}@${ip}" \
  "echo '${BUILD_PASSWORD}' | sudo -S -p '' \
     env GOSS_SPEC=/tmp/${spec_name} BUILD_USERNAME=${BUILD_USERNAME} \
     bash /tmp/goss-validate.sh"

rc=$?
if [[ ${rc} -ne 0 ]]; then
  echo "❌ Smoke test FAILED on clone ${CLONE_NAME} (goss exit ${rc})"
  exit ${rc}
fi

echo ""
echo "✅ Smoke test PASSED on clone of ${template}"

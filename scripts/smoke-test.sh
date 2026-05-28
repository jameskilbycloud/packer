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
SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-180}"

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

cleanup() {
  local rc=$?
  echo ""
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
while [[ $(date +%s) -lt ${deadline} ]]; do
  ip=$(govc vm.ip -wait=30s "${CLONE_NAME}" 2>/dev/null || true)
  if [[ -n "${ip}" ]]; then
    break
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
trap 'rm -rf "${keydir}"; cleanup' EXIT
ssh-keygen -t ed25519 -N '' -f "${keydir}/id_ed25519" \
  -C "smoke-test-${GITHUB_RUN_ID:-local}" >/dev/null
chmod 600 "${keydir}/id_ed25519"

guest_auth=(-l "${BUILD_USERNAME}:${BUILD_PASSWORD}" -vm "${CLONE_NAME}")

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

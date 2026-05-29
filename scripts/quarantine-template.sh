#!/usr/bin/env bash
# =============================================================================
# quarantine-template.sh
# Move a smoke-failed template out of the live folder so clone consumers can
# not accidentally pick it up. Called by the post-publish smoke job when the
# smoke test exits non-zero against the just-built template.
#
# Behaviour:
#   - Locate the newest template matching TEMPLATE_PATTERN (same logic as
#     smoke-test.sh — they target the same artefact).
#   - Ensure the quarantine folder exists at
#     /<DC>/vm/<VSPHERE_FOLDER>/quarantine/.
#   - Rename the template, appending `-quarantined-r<RUN_NUMBER>` so:
#       1. it is visually distinct from live templates in vSphere
#       2. prune-templates.sh's group key (${name%-*}) treats it as its own
#          single-member group, never collapsed into the live retention policy
#          (defence-in-depth — prune-templates.sh also skips */quarantine/*).
#   - Move it into the quarantine folder.
#   - Annotate it with the failing run's URL so an operator can jump straight
#     from vSphere back to the build logs.
#
# Required env:
#   GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_DATACENTER
#   VSPHERE_FOLDER     — parent folder; quarantine subfolder lives under this
#   TEMPLATE_PATTERN   — glob matching the template (e.g. "ubuntu-2404-server-*")
#   RUN_NUMBER         — GitHub Actions run number (used in the rename suffix)
#
# Optional env:
#   GOVC_INSECURE      — default "false"
#   QUARANTINE_FOLDER  — override the destination folder name (default: quarantine)
#   RUN_URL            — link written into the VM annotation
# =============================================================================
set -euo pipefail

: "${GOVC_URL:?Set GOVC_URL}"
: "${GOVC_USERNAME:?Set GOVC_USERNAME}"
: "${GOVC_PASSWORD:?Set GOVC_PASSWORD}"
: "${GOVC_DATACENTER:?Set GOVC_DATACENTER}"
: "${VSPHERE_FOLDER:?Set VSPHERE_FOLDER (parent folder under /<DC>/vm)}"
: "${TEMPLATE_PATTERN:?Set TEMPLATE_PATTERN to the template glob}"
: "${RUN_NUMBER:?Set RUN_NUMBER (used in the rename suffix)}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER
export GOVC_INSECURE="${GOVC_INSECURE:-false}"

QUARANTINE_FOLDER="${QUARANTINE_FOLDER:-quarantine}"
RUN_URL="${RUN_URL:-(unknown)}"

# ── Locate the newest live template matching the pattern ─────────────────────
# Mirrors smoke-test.sh: newest-first sort over `govc find`, first match with
# config.template=true wins. Skip anything already in the quarantine folder
# so re-runs of an already-quarantined template don't try to quarantine it
# twice.
echo "==> Locating newest live template matching '${TEMPLATE_PATTERN}'..."
matches=$(govc find . -type m -name "${TEMPLATE_PATTERN}" 2>/dev/null || true)
if [[ -z "${matches}" ]]; then
  echo "⚠️  No VMs match '${TEMPLATE_PATTERN}' — nothing to quarantine."
  exit 0
fi

template=""
while IFS= read -r p; do
  [[ -z "${p}" ]] && continue
  case "${p}" in
    */${QUARANTINE_FOLDER}/*) continue ;;
  esac
  is_tpl=$(govc object.collect -s "${p}" config.template 2>/dev/null || echo "")
  if [[ "${is_tpl}" == "true" ]]; then
    template="${p}"
    break
  fi
done < <(printf '%s\n' "${matches}" | sed '/^$/d' | sort -r)

if [[ -z "${template}" ]]; then
  echo "⚠️  No live (non-quarantined) template found among matches — nothing to do."
  exit 0
fi
echo "    template: ${template}"

# ── Ensure the quarantine folder exists ──────────────────────────────────────
# Walk each path component the same way build-templates.yml ensures the live
# folder exists. govc folder.create errors on existing folders; swallow with
# `|| true` so the loop is idempotent.
parent="/${GOVC_DATACENTER}/vm"
IFS='/' read -ra parts <<< "${VSPHERE_FOLDER}/${QUARANTINE_FOLDER}"
for part in "${parts[@]}"; do
  [[ -z "${part}" ]] && continue
  parent="${parent}/${part}"
  govc folder.create "${parent}" 2>/dev/null || true
done
target_folder="${parent}"
echo "    quarantine folder: ${target_folder}"

# ── Rename the template ──────────────────────────────────────────────────────
# `govc object.rename` is the generic rename for any managed entity and works
# on templates (which `vm.change -name` sometimes refuses depending on govc
# version). The new name re-uses the existing date suffix and appends
# `-quarantined-r<RUN_NUMBER>`.
old_name="${template##*/}"
new_name="${old_name}-quarantined-r${RUN_NUMBER}"
parent_path="${template%/*}"
renamed_path="${parent_path}/${new_name}"

echo "    rename: ${old_name} → ${new_name}"
if ! govc object.rename "${template}" "${new_name}"; then
  echo "❌ Rename failed; leaving the template in place. Manual investigation required."
  exit 1
fi

# ── Move into the quarantine folder ──────────────────────────────────────────
echo "    move:   ${renamed_path} → ${target_folder}/"
if ! govc object.mv "${renamed_path}" "${target_folder}"; then
  echo "❌ Move failed; the template was renamed but stayed in ${parent_path}."
  echo "   Manual cleanup: govc object.mv '${renamed_path}' '${target_folder}'"
  exit 1
fi

# ── Annotate with the failing run URL ────────────────────────────────────────
final_path="${target_folder}/${new_name}"
annotation="Quarantined by smoke-test failure in run #${RUN_NUMBER}. Build log: ${RUN_URL}"
if ! govc vm.change -vm "${final_path}" -annotation "${annotation}" 2>/dev/null; then
  echo "    (annotation update failed — non-fatal)"
fi

echo ""
echo "✅ Template quarantined at: ${final_path}"
echo "   ${annotation}"

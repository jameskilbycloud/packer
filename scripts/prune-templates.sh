#!/usr/bin/env bash
# =============================================================================
# prune-templates.sh
# Template retention / rotation policy.
#
# Lists VM-templates in vSphere matching a name pattern, groups them by name
# prefix (everything before the trailing `-YYYYMMDD` date suffix), keeps the
# N most recent per group, and destroys the rest.
#
# Used in two places:
#   - build-templates.yml — runs after each successful build to retire the
#                            oldest template in the just-built group.
#   - rotate-templates.yml — runs on a schedule (manual + monthly cron) to
#                             prune ALL groups in one pass, independent of
#                             the build cadence.
#
# Required env:
#   GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_DATACENTER
#
# Optional env:
#   GOVC_INSECURE      — default "false"
#   NAME_PATTERN       — glob passed to `govc find -name`, e.g. "ubuntu-2604-*"
#                        Defaults to "ubuntu-*" which covers everything this
#                        repo produces.
#   RETAIN             — how many templates to keep per group (default: 2)
#   DRY_RUN            — "true" prints intent without destroying (default: false)
#
# Grouping: templates are named `ubuntu-<version>-<type>-<YYYYMMDD>`. The
# group key is `${name%-*}` — everything before the trailing date suffix.
# Combined globs (e.g. `ubuntu-2604-*`) correctly retain N server AND N
# desktop, not N total interleaved.
# =============================================================================
set -euo pipefail

: "${GOVC_URL:?Set GOVC_URL}"
: "${GOVC_USERNAME:?Set GOVC_USERNAME}"
: "${GOVC_PASSWORD:?Set GOVC_PASSWORD}"
: "${GOVC_DATACENTER:?Set GOVC_DATACENTER}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER
export GOVC_INSECURE="${GOVC_INSECURE:-false}"

NAME_PATTERN="${NAME_PATTERN:-ubuntu-*}"
RETAIN="${RETAIN:-2}"
DRY_RUN="${DRY_RUN:-false}"

echo "Retention policy: keep ${RETAIN} templates per (version, type) group"
echo "Pattern: ${NAME_PATTERN}"
[[ "${DRY_RUN}" == "true" ]] && echo "*** DRY RUN — no templates will be destroyed ***"
echo ""

matches=$(govc find . -type m -name "${NAME_PATTERN}" 2>/dev/null || true)
if [[ -z "${matches}" ]]; then
  echo "No items matching '${NAME_PATTERN}' — nothing to prune."
  exit 0
fi

# Filter to actual templates; in-flight VMs from a concurrent run must not
# be touched.
_is_tpl='import sys,json;vms=(json.load(sys.stdin) or {}).get("VirtualMachines",[]);print("true" if vms and vms[0].get("Config",{}).get("Template",False) else "false")'

declare -A by_group
# Sentinel: ${#by_group[@]} on an empty associative array trips `set -u`'s
# unbound-variable check on bash <4.4 and some 5.x patch levels — and we
# expect by_group to be empty when every match is a WIP VM. Track via an
# explicit counter instead.
have_groups=0
groups_order=()

while IFS= read -r vm_path; do
  [[ -z "${vm_path}" ]] && continue
  info=$(govc vm.info -json "${vm_path}" 2>/dev/null || true)
  is_template=$(printf '%s' "${info}" | python3 -c "${_is_tpl}" 2>/dev/null || echo "false")
  if [[ "${is_template}" != "true" ]]; then
    # Distinguish "vm.info returned no data" from "really not a template" so
    # an inspector can tell whether the path actually resolved.
    if [[ -z "${info}" ]]; then
      echo "  skip (vm.info returned nothing — path may not resolve): ${vm_path}"
    else
      echo "  skip (not a template): ${vm_path}"
    fi
    continue
  fi
  name="${vm_path##*/}"
  group="${name%-*}"          # strip trailing -YYYYMMDD
  if [[ -z "${by_group[$group]+x}" ]]; then
    groups_order+=("$group")
  fi
  by_group[$group]+="${vm_path}"$'\n'
  have_groups=1
done <<< "${matches}"

if [[ ${have_groups} -eq 0 ]]; then
  echo ""
  echo "No templates found among matched items — nothing to prune."
  echo "(All matches were either WIP VMs or could not be inspected.)"
  exit 0
fi

destroyed=0
for group in "${groups_order[@]}"; do
  echo ""
  echo "=== Group: ${group} ==="
  # Sort by full path desc; YYYYMMDD suffix is zero-padded so lex desc == newest-first.
  sorted=$(printf "%s" "${by_group[$group]}" | sed '/^$/d' | sort -r)
  count=0
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    count=$((count + 1))
    if [[ ${count} -le ${RETAIN} ]]; then
      printf "  KEEP    [%d/%s]: %s\n" "${count}" "${RETAIN}" "${p}"
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        printf "  WOULD DESTROY  : %s\n" "${p}"
      else
        printf "  DESTROY        : %s\n" "${p}"
        if govc vm.destroy "${p}"; then
          destroyed=$((destroyed + 1))
        else
          echo "    ✘ destroy failed for ${p} — continuing"
        fi
      fi
    fi
  done <<< "${sorted}"
done

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run complete. No templates were destroyed."
else
  echo "Prune complete. Destroyed: ${destroyed} template(s)."
fi

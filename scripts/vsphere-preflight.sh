#!/usr/bin/env bash
# =============================================================================
# vsphere-preflight.sh
# Fast vCenter / datastore / content library health check.
#
# Runs at the start of a Packer build so a sick vCenter does not burn the full
# 30m ssh_timeout per matrix leg before the failure surfaces. Designed to
# complete in well under a minute against a healthy environment; any failure
# returns a non-zero exit code with a clear "✗" line pointing at the
# offending check.
#
# Required env:
#   GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_DATACENTER
#   VSPHERE_DATASTORE          — build datastore name
#
# Optional env:
#   GOVC_INSECURE              — default "false"
#   VSPHERE_CLUSTER            — if set, verified reachable
#   VSPHERE_HOST               — if set, verified reachable
#   CONTENT_LIBRARY            — default "Packer-ISOs"
#   PREFLIGHT_MIN_FREE_GB      — minimum free space on build datastore
#                                (default 60 — covers a combined server+desktop
#                                 build with headroom for ephemeral clones)
# =============================================================================
set -euo pipefail

: "${GOVC_URL:?Set GOVC_URL}"
: "${GOVC_USERNAME:?Set GOVC_USERNAME}"
: "${GOVC_PASSWORD:?Set GOVC_PASSWORD}"
: "${GOVC_DATACENTER:?Set GOVC_DATACENTER}"
: "${VSPHERE_DATASTORE:?Set VSPHERE_DATASTORE (build datastore name)}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER
export GOVC_INSECURE="${GOVC_INSECURE:-false}"

CONTENT_LIBRARY="${CONTENT_LIBRARY:-Packer-ISOs}"
MIN_FREE_GB="${PREFLIGHT_MIN_FREE_GB:-60}"

fail=0
note() { printf '    %s\n' "$*"; }
ok()   { printf '    \xe2\x9c\x93 %s\n' "$*"; }
bad()  { printf '    \xe2\x9c\x97 %s\n' "$*"; fail=1; }

# ── 1. vCenter reachability + auth ────────────────────────────────────────────
echo "==> vCenter reachability"
if about=$(govc about 2>&1); then
  vendor=$(printf '%s\n' "${about}"  | awk -F': *' '/^Vendor:/   {print $2; exit}')
  version=$(printf '%s\n' "${about}" | awk -F': *' '/^Version:/  {print $2; exit}')
  build=$(printf '%s\n' "${about}"   | awk -F': *' '/^Build:/    {print $2; exit}')
  ok "Connected: ${vendor:-?} ${version:-?} build ${build:-?}"
else
  bad "govc about failed — vCenter unreachable or credentials wrong:"
  printf '%s\n' "${about}" | sed 's/^/        /'
fi

# ── 2. Datacenter exists ──────────────────────────────────────────────────────
echo "==> Datacenter"
if govc datacenter.info "/${GOVC_DATACENTER}" >/dev/null 2>&1; then
  ok "Datacenter '${GOVC_DATACENTER}' reachable"
else
  bad "Datacenter '${GOVC_DATACENTER}' not found"
fi

# ── 3. Cluster / host reachable (only checks what was set) ────────────────────
if [[ -n "${VSPHERE_CLUSTER:-}" ]]; then
  echo "==> Cluster"
  if govc find -type c -name "${VSPHERE_CLUSTER}" 2>/dev/null | grep -q .; then
    ok "Cluster '${VSPHERE_CLUSTER}' reachable"
  else
    bad "Cluster '${VSPHERE_CLUSTER}' not found"
  fi
fi
if [[ -n "${VSPHERE_HOST:-}" ]]; then
  echo "==> Host"
  if govc find -type h -name "${VSPHERE_HOST}" 2>/dev/null | grep -q .; then
    ok "Host '${VSPHERE_HOST}' reachable"
  else
    bad "Host '${VSPHERE_HOST}' not found"
  fi
fi

# ── 4. Datastore exists + has enough free space ───────────────────────────────
# `govc datastore.info -json` returns Datastores[].Summary.{FreeSpace,Capacity}
# as bytes. Parse via python so we are robust to unit-formatting drift in the
# plain-text output.
echo "==> Datastore '${VSPHERE_DATASTORE}'"
ds_json=$(govc datastore.info -json "${VSPHERE_DATASTORE}" 2>&1) || ds_json=""
# `grep -qiE` matches both the old PascalCase ("FreeSpace") and the newer
# lowercase-first ("freeSpace") govc JSON output schemas — the python
# parser below already handles both, so the gate has to too. Without this,
# a successful govc datastore.info call gets reported as "not reachable"
# whenever the installed govc emits the lowercase form — preflight had
# a regression where it reported a healthy datastore as unreachable until
# the case-insensitive match was added.
if [[ -z "${ds_json}" ]] || ! printf '%s' "${ds_json}" | grep -qiE '"freespace"'; then
  bad "Datastore '${VSPHERE_DATASTORE}' not reachable:"
  printf '%s\n' "${ds_json}" | sed 's/^/        /'
else
  read -r free_bytes cap_bytes < <(printf '%s' "${ds_json}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
arr = d.get("Datastores", d.get("datastores", []))
if arr:
    s = arr[0].get("Summary", arr[0].get("summary", {}))
    print(s.get("FreeSpace", s.get("freeSpace", 0)),
          s.get("Capacity",  s.get("capacity",  0)))
else:
    print("0 0")
')
  free_gb=$((free_bytes / 1024 / 1024 / 1024))
  cap_gb=$((cap_bytes  / 1024 / 1024 / 1024))
  if [[ ${cap_gb} -gt 0 ]]; then
    pct=$((100 * free_gb / cap_gb))
  else
    pct=0
  fi
  note "Free: ${free_gb} GiB / ${cap_gb} GiB (${pct}%)"
  if [[ ${free_gb} -ge ${MIN_FREE_GB} ]]; then
    ok "Free space \xe2\x89\xa5 ${MIN_FREE_GB} GiB threshold"
  else
    bad "Free space ${free_gb} GiB is below the ${MIN_FREE_GB} GiB threshold"
  fi
fi

# ── 5. Content library health ─────────────────────────────────────────────────
# Lightweight: library exists + has at least one item. The per-version ISO
# resolution in build-templates.yml does the deeper check on the matrix
# entry's actual ISO — this is just a "library is alive" gate.
echo "==> Content library '${CONTENT_LIBRARY}'"
if lib_listing=$(govc library.ls "/${CONTENT_LIBRARY}/" 2>&1); then
  trimmed=$(printf '%s\n' "${lib_listing}" | sed '/^$/d')
  if [[ -z "${trimmed}" ]]; then
    bad "Library '${CONTENT_LIBRARY}' exists but is empty — upload ISOs first"
  else
    item_count=$(printf '%s\n' "${trimmed}" | grep -c .)
    # Content Library items are named after the source file but WITHOUT the
    # extension by default (e.g. ubuntu-22.04.5-live-server-amd64 not
    # ubuntu-22.04.5-live-server-amd64.iso). Match items whose name carries
    # the ubuntu-XX.XX(.X)? prefix as the "ISO-shaped item" heuristic.
    iso_count=$(printf '%s\n' "${trimmed}" | grep -icE '(^|/)ubuntu-[0-9]+\.[0-9]+' || true)
    ok "Library reachable: ${item_count} item(s), ${iso_count} ubuntu ISO(s)"
  fi
else
  bad "Library '${CONTENT_LIBRARY}' not reachable:"
  printf '%s\n' "${lib_listing}" | sed 's/^/        /'
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ ${fail} -eq 0 ]]; then
  echo "✅ Pre-flight passed — environment looks healthy for build."
  exit 0
else
  echo "❌ Pre-flight failed — fix the items above before retriggering the build."
  echo "   (This saves the 30m ssh_timeout you would otherwise burn per matrix leg.)"
  exit 1
fi

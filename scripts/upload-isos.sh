#!/usr/bin/env bash
# =============================================================================
# upload-isos.sh
# Downloads Ubuntu live-server ISOs and uploads them to a vSphere Content
# Library using govc.
#
# Requirements:
#   govc  — https://github.com/vmware/govmomi/releases
#   curl
#   sha256sum (Linux) or shasum (macOS — handled automatically)
#
# Usage:
#   export GOVC_URL="https://vcenter.example.com"
#   export GOVC_USERNAME="administrator@vsphere.local"
#   export GOVC_PASSWORD="secret"
#   export GOVC_DATACENTER="Datacenter"
#   export LIBRARY_DATASTORE="datastore1"
#   ./scripts/upload-isos.sh
#
#   Or override any variable inline:
#   CONTENT_LIBRARY=MyISOs UBUNTU_VERSIONS="2404" ./scripts/upload-isos.sh
#
# Environment variables (all overridable):
#   GOVC_URL            — vCenter HTTPS URL                     (required)
#   GOVC_USERNAME       — vCenter username                      (required)
#   GOVC_PASSWORD       — vCenter password                      (required)
#   GOVC_INSECURE       — skip TLS verification (true/false)    (default: false)
#   GOVC_DATACENTER     — vSphere datacenter name               (required)
#   CONTENT_LIBRARY     — Content Library name to create/use    (default: Packer-ISOs)
#   LIBRARY_DATASTORE   — Datastore to back the library         (required)
#   UBUNTU_VERSIONS     — Space-separated versions to process   (default: 2204 2404 2604)
#   DOWNLOAD_DIR        — Local temp dir for ISO downloads      (default: /tmp/packer-isos)
#   KEEP_DOWNLOADS      — Set to "true" to keep local ISOs      (default: false)
#   SKIP_CHECKSUM       — Set to "true" to skip SHA256 check    (default: false)
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
# Disable colour when running inside GitHub Actions or when NO_COLOR is set,
# so escape sequences don't litter the Actions log viewer.
if [[ -z "${GITHUB_ACTIONS:-}" && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { echo -e "${CYAN}==>${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✘${RESET}  $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ─────────────────────────────────────────────${RESET}"; }

# ── Required environment ───────────────────────────────────────────────────────
: "${GOVC_URL:?Set GOVC_URL to your vCenter URL (e.g. https://vcenter.example.com)}"
: "${GOVC_USERNAME:?Set GOVC_USERNAME (e.g. administrator@vsphere.local)}"
: "${GOVC_PASSWORD:?Set GOVC_PASSWORD}"
: "${GOVC_DATACENTER:?Set GOVC_DATACENTER to your datacenter name}"
: "${LIBRARY_DATASTORE:?Set LIBRARY_DATASTORE to the datastore that will back the content library}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER
export GOVC_INSECURE="${GOVC_INSECURE:-false}"

# ── Optional configuration ─────────────────────────────────────────────────────
CONTENT_LIBRARY="${CONTENT_LIBRARY:-Packer-ISOs}"
UBUNTU_VERSIONS="${UBUNTU_VERSIONS:-2204 2404 2604}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/packer-isos}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-false}"
SKIP_CHECKSUM="${SKIP_CHECKSUM:-false}"

# ── ISO catalogue ──────────────────────────────────────────────────────────────
# Update filenames here when Ubuntu releases new point releases.
declare -A ISO_FILENAME=(
  [2204]="ubuntu-22.04.4-live-server-amd64.iso"
  [2404]="ubuntu-24.04.2-live-server-amd64.iso"
  [2604]="ubuntu-26.04-live-server-amd64.iso"
)

declare -A ISO_BASE_URL=(
  [2204]="https://releases.ubuntu.com/22.04"
  [2404]="https://releases.ubuntu.com/24.04"
  [2604]="https://releases.ubuntu.com/26.04"
)

declare -A ISO_LABEL=(
  [2204]="Ubuntu 22.04 LTS (Jammy Jellyfish)"
  [2404]="Ubuntu 24.04 LTS (Noble Numbat)"
  [2604]="Ubuntu 26.04 LTS (Plucky Puffin)"
)

# Track results for summary
declare -A BUILD_STATUS=()

# ── Prerequisites ──────────────────────────────────────────────────────────────
check_prerequisites() {
  header "Checking prerequisites"

  local missing=0

  if ! command -v govc &>/dev/null; then
    error "govc not found. Download from https://github.com/vmware/govmomi/releases"
    missing=1
  else
    success "govc found: $(govc version 2>/dev/null | head -1)"
  fi

  if ! command -v curl &>/dev/null; then
    error "curl not found. Install via your package manager."
    missing=1
  else
    success "curl found"
  fi

  # sha256sum (Linux) or shasum -a 256 (macOS)
  if command -v sha256sum &>/dev/null; then
    SHA256_CMD="sha256sum"
    success "sha256sum found"
  elif command -v shasum &>/dev/null; then
    SHA256_CMD="shasum -a 256"
    success "shasum found (macOS)"
  else
    if [[ "${SKIP_CHECKSUM}" != "true" ]]; then
      error "sha256sum / shasum not found. Set SKIP_CHECKSUM=true to bypass, or install coreutils."
      missing=1
    fi
  fi

  [[ "${missing}" -eq 0 ]] || { error "Missing prerequisites — aborting."; exit 1; }
}

# ── vSphere connection ─────────────────────────────────────────────────────────
verify_govc_connection() {
  header "Verifying vSphere connection"
  info "Connecting to ${GOVC_URL} as ${GOVC_USERNAME}..."

  local govc_out
  if govc_out=$(govc about 2>&1); then
    local vc_info
    vc_info=$(echo "${govc_out}" | grep -E "Name:|Version:" | sed 's/^/  /')
    success "Connected to vCenter"
    echo -e "${vc_info}"
  else
    error "Could not connect to vCenter:"
    # Print the actual govc error so the cause is visible in the log
    echo "${govc_out}" | sed 's/^/  /' >&2
    echo "" >&2
    error "Common causes:"
    echo "  • GOVC_URL must include the scheme — e.g. https://vcenter.example.com" >&2
    echo "  • Self-signed cert? Set GOVC_INSECURE=true (VSPHERE_INSECURE secret)" >&2
    echo "  • Verify VSPHERE_USER / VSPHERE_PASSWORD are correct" >&2
    exit 1
  fi
}

# ── Content Library ────────────────────────────────────────────────────────────
ensure_content_library() {
  header "Content Library: ${CONTENT_LIBRARY}"

  # govc library.info exits 0 even when the library doesn't exist, so check
  # for actual output from library.ls instead.
  if govc library.ls 2>/dev/null | grep -qF "/${CONTENT_LIBRARY}"; then
    success "Content library '${CONTENT_LIBRARY}' already exists"
  else
    info "Creating content library '${CONTENT_LIBRARY}' on datastore '${LIBRARY_DATASTORE}'..."
    govc library.create \
      -ds "${LIBRARY_DATASTORE}" \
      "${CONTENT_LIBRARY}"
    success "Content library created"
  fi
}

# ── Checksum verification ──────────────────────────────────────────────────────
verify_checksum() {
  local iso_file="$1"
  local base_url="$2"
  local filename
  filename=$(basename "${iso_file}")

  if [[ "${SKIP_CHECKSUM}" == "true" ]]; then
    warn "Checksum verification skipped (SKIP_CHECKSUM=true)"
    return 0
  fi

  info "Downloading SHA256SUMS..."
  local sums_file="${DOWNLOAD_DIR}/SHA256SUMS.${filename}"
  curl -fsSL "${base_url}/SHA256SUMS" -o "${sums_file}"

  local expected_hash
  expected_hash=$(grep " \*${filename}$\| ${filename}$" "${sums_file}" | awk '{print $1}')

  if [[ -z "${expected_hash}" ]]; then
    warn "Could not find checksum for '${filename}' in SHA256SUMS — skipping verification"
    return 0
  fi

  info "Verifying SHA256 checksum..."
  local actual_hash
  actual_hash=$(${SHA256_CMD} "${iso_file}" | awk '{print $1}')

  if [[ "${expected_hash}" == "${actual_hash}" ]]; then
    success "Checksum verified: ${actual_hash:0:16}..."
  else
    error "Checksum MISMATCH for ${filename}"
    error "  Expected : ${expected_hash}"
    error "  Actual   : ${actual_hash}"
    return 1
  fi
}

# ── ISO download ───────────────────────────────────────────────────────────────
download_iso() {
  local version="$1"
  local filename="${ISO_FILENAME[${version}]}"
  local base_url="${ISO_BASE_URL[${version}]}"
  local iso_url="${base_url}/${filename}"
  local iso_path="${DOWNLOAD_DIR}/${filename}"

  if [[ -f "${iso_path}" ]]; then
    info "Found existing download: ${iso_path}"
    info "Attempting to resume / verify..."
    # Try to resume; curl will confirm file is complete if server supports it
    curl -fL --continue-at - \
      --progress-bar \
      -o "${iso_path}" \
      "${iso_url}" || true
  else
    info "Downloading ${filename}..."
    info "Source: ${iso_url}"
    curl -fL --continue-at - \
      --progress-bar \
      -o "${iso_path}" \
      "${iso_url}"
  fi

  verify_checksum "${iso_path}" "${base_url}"
  echo "${iso_path}"
}

# ── Library item existence check ───────────────────────────────────────────────
library_item_exists() {
  local lib="$1"
  local item_name="$2"

  # govc library.info exits 0 even when the item doesn't exist, so check for
  # actual output from library.ls instead.
  govc library.ls "${lib}/" 2>/dev/null | grep -qF "${item_name}"
}

# ── Upload to Content Library ──────────────────────────────────────────────────
upload_iso() {
  local version="$1"
  local iso_path="$2"
  local filename
  filename=$(basename "${iso_path}")

  info "Uploading to content library '${CONTENT_LIBRARY}'..."
  info "  Item name : ${filename}"
  info "  File size : $(du -sh "${iso_path}" | cut -f1)"

  # -n sets the library item name explicitly (preserves .iso extension)
  govc library.import \
    -n "${filename}" \
    "${CONTENT_LIBRARY}" \
    "${iso_path}"

  success "Upload complete: ${filename}"
}

# ── Process a single Ubuntu version ───────────────────────────────────────────
process_version() {
  local version="$1"
  local label="${ISO_LABEL[${version}]:-Ubuntu ${version}}"
  local filename="${ISO_FILENAME[${version}]}"

  header "${label}"

  # Check if ISO filename is a placeholder (26.04 may not have a final name yet)
  if [[ "${filename}" == *"PLACEHOLDER"* ]]; then
    warn "No ISO filename configured for ${version} — set ISO_FILENAME[${version}] and re-run"
    BUILD_STATUS[${version}]="SKIPPED (no filename)"
    return 0
  fi

  # Skip if already in library
  if library_item_exists "${CONTENT_LIBRARY}" "${filename}"; then
    success "Already in content library: ${filename}"
    BUILD_STATUS[${version}]="SKIPPED (already present)"
    return 0
  fi

  # Download
  local iso_path
  iso_path=$(download_iso "${version}")

  # Upload
  upload_iso "${version}" "${iso_path}"
  BUILD_STATUS[${version}]="UPLOADED"

  # Clean up local file unless KEEP_DOWNLOADS=true
  if [[ "${KEEP_DOWNLOADS}" != "true" ]]; then
    info "Removing local ISO (set KEEP_DOWNLOADS=true to retain it)"
    rm -f "${iso_path}"
  else
    info "Kept local ISO at: ${iso_path}"
  fi
}

# ── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
  header "Summary"

  echo ""
  printf "  %-8s  %-40s  %s\n" "VERSION" "ISO" "STATUS"
  printf "  %-8s  %-40s  %s\n" "-------" "---" "------"
  for version in ${UBUNTU_VERSIONS}; do
    local filename="${ISO_FILENAME[${version}]:-N/A}"
    local status="${BUILD_STATUS[${version}]:-NOT PROCESSED}"
    local colour="${RESET}"
    [[ "${status}" == "UPLOADED" ]]             && colour="${GREEN}"
    [[ "${status}" == SKIPPED* ]]               && colour="${YELLOW}"
    [[ "${status}" == "FAILED"* ]]              && colour="${RED}"
    printf "  %-8s  %-40s  ${colour}%s${RESET}\n" "${version}" "${filename}" "${status}"
  done
  echo ""

  info "Content library : ${CONTENT_LIBRARY}"
  info "vCenter         : ${GOVC_URL}"
  echo ""
  echo -e "${BOLD}Packer variables to use in variables.pkrvars.hcl:${RESET}"
  echo ""
  echo "  vsphere_iso_datastore = \"${CONTENT_LIBRARY}\""
  for version in ${UBUNTU_VERSIONS}; do
    local filename="${ISO_FILENAME[${version}]:-}"
    [[ -n "${filename}" ]] && \
      echo "  ubuntu_${version}_iso_path  = \"${filename}\""
  done
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}Packer ISO Uploader — vSphere Content Library${RESET}"
  echo -e "Processing versions: ${UBUNTU_VERSIONS}"
  echo ""

  check_prerequisites
  verify_govc_connection
  ensure_content_library

  mkdir -p "${DOWNLOAD_DIR}"

  local failed=0
  for version in ${UBUNTU_VERSIONS}; do
    if ! process_version "${version}"; then
      BUILD_STATUS[${version}]="FAILED"
      failed=1
    fi
  done

  print_summary

  [[ "${failed}" -eq 0 ]] || { error "One or more uploads failed. Check output above."; exit 1; }
  success "Done."
}

main "$@"

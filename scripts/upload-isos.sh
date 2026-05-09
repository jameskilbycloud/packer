#!/usr/bin/env bash
# =============================================================================
# upload-isos.sh
# Downloads Ubuntu live-server ISOs and imports them into a vSphere Content
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
#   GOVC_URL          — vCenter HTTPS URL                     (required)
#   GOVC_USERNAME     — vCenter username                      (required)
#   GOVC_PASSWORD     — vCenter password                      (required)
#   GOVC_INSECURE     — skip TLS verification (true/false)    (default: false)
#   GOVC_DATACENTER   — vSphere datacenter name               (required)
#   LIBRARY_DATASTORE — Datastore that backs the library      (required)
#   CONTENT_LIBRARY   — Content Library name                  (default: Packer-ISOs)
#   UBUNTU_VERSIONS   — Space-separated versions to process   (default: 2204 2404 2604)
#   DOWNLOAD_DIR      — Local temp dir for ISO downloads      (default: /var/tmp/packer-isos)
#   KEEP_DOWNLOADS    — Set to "true" to keep local ISOs      (default: false)
#   SKIP_CHECKSUM     — Set to "true" to skip SHA256 check    (default: false)
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
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
: "${GOVC_URL:?Set GOVC_URL to your vCenter URL}"
: "${GOVC_USERNAME:?Set GOVC_USERNAME}"
: "${GOVC_PASSWORD:?Set GOVC_PASSWORD}"
: "${GOVC_DATACENTER:?Set GOVC_DATACENTER}"
: "${LIBRARY_DATASTORE:?Set LIBRARY_DATASTORE to the datastore backing the Content Library}"

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER
export GOVC_INSECURE="${GOVC_INSECURE:-false}"

# ── Optional configuration ─────────────────────────────────────────────────────
CONTENT_LIBRARY="${CONTENT_LIBRARY:-Packer-ISOs}"
UBUNTU_VERSIONS="${UBUNTU_VERSIONS:-2204 2404 2604}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/var/tmp/packer-isos}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-false}"
SKIP_CHECKSUM="${SKIP_CHECKSUM:-false}"

# ── ISO catalogue ──────────────────────────────────────────────────────────────
declare -A ISO_FILENAME=(
  [2204]="ubuntu-22.04.5-live-server-amd64.iso"
  [2404]="ubuntu-24.04.4-live-server-amd64.iso"
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

declare -A BUILD_STATUS=()
DOWNLOADED_ISO_PATH=""

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
    error "curl not found."
    missing=1
  else
    success "curl found"
  fi

  if command -v sha256sum &>/dev/null; then
    SHA256_CMD="sha256sum"
    success "sha256sum found"
  elif command -v shasum &>/dev/null; then
    SHA256_CMD="shasum -a 256"
    success "shasum found (macOS)"
  else
    if [[ "${SKIP_CHECKSUM}" != "true" ]]; then
      error "sha256sum / shasum not found. Set SKIP_CHECKSUM=true to bypass."
      missing=1
    fi
  fi

  local version_count
  version_count=$(echo "${UBUNTU_VERSIONS}" | wc -w)
  local required_gb
  if [[ "${KEEP_DOWNLOADS}" == "true" ]]; then
    required_gb=$(( version_count * 2 + 1 ))
  else
    required_gb=3
  fi
  mkdir -p "${DOWNLOAD_DIR}"
  local avail_kb avail_gb
  avail_kb=$(df -k "${DOWNLOAD_DIR}" | awk 'NR==2 {print $4}')
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [[ "${avail_gb}" -lt "${required_gb}" ]]; then
    error "Insufficient disk space in ${DOWNLOAD_DIR} (need ~${required_gb} GB, have ~${avail_gb} GB)"
    missing=1
  else
    success "Disk space OK: ~${avail_gb} GB in ${DOWNLOAD_DIR}"
  fi

  [[ "${missing}" -eq 0 ]] || { error "Missing prerequisites — aborting."; exit 1; }
}

# ── vSphere connection ─────────────────────────────────────────────────────────
verify_govc_connection() {
  header "Verifying vSphere connection"
  local govc_out
  if govc_out=$(govc about 2>&1); then
    success "Connected to vCenter"
    echo "${govc_out}" | grep -E "Name:|Version:" | sed 's/^/  /'
  else
    error "Could not connect to vCenter:"
    echo "${govc_out}" | sed 's/^/  /' >&2
    echo "  • GOVC_URL must include the scheme — e.g. https://vcenter.example.com" >&2
    echo "  • Self-signed cert? Set GOVC_INSECURE=true" >&2
    exit 1
  fi
}

# ── Content Library ────────────────────────────────────────────────────────────
ensure_content_library() {
  header "Content Library: ${CONTENT_LIBRARY}"
  if [[ -n "$(govc library.ls "/${CONTENT_LIBRARY}" 2>/dev/null)" ]]; then
    success "Library exists: ${CONTENT_LIBRARY}"
  else
    info "Creating Content Library '${CONTENT_LIBRARY}' on datastore '${LIBRARY_DATASTORE}'..."
    govc library.create -ds="${LIBRARY_DATASTORE}" "${CONTENT_LIBRARY}"
    success "Library created: ${CONTENT_LIBRARY}"
  fi
}

# ── Checksum ───────────────────────────────────────────────────────────────────
verify_checksum() {
  local iso_file="$1" base_url="$2"
  local filename; filename=$(basename "${iso_file}")

  if [[ "${SKIP_CHECKSUM}" == "true" ]]; then
    warn "Checksum verification skipped"
    return 0
  fi

  info "Downloading SHA256SUMS..."
  local sums_file="${DOWNLOAD_DIR}/SHA256SUMS.${filename}"
  curl -fsSL "${base_url}/SHA256SUMS" -o "${sums_file}"

  local expected_hash
  expected_hash=$(grep " \*${filename}$\| ${filename}$" "${sums_file}" | awk '{print $1}')
  if [[ -z "${expected_hash}" ]]; then
    warn "Checksum for '${filename}' not found in SHA256SUMS — skipping"
    return 0
  fi

  local actual_hash
  actual_hash=$(${SHA256_CMD} "${iso_file}" | awk '{print $1}')
  if [[ "${expected_hash}" == "${actual_hash}" ]]; then
    success "Checksum OK: ${actual_hash:0:16}..."
  else
    error "Checksum MISMATCH — expected ${expected_hash}, got ${actual_hash}"
    return 1
  fi
}

# ── ISO download ───────────────────────────────────────────────────────────────
download_iso() {
  local version="$1"
  local filename="${ISO_FILENAME[${version}]}"
  local base_url="${ISO_BASE_URL[${version}]}"
  local iso_path="${DOWNLOAD_DIR}/${filename}"

  DOWNLOADED_ISO_PATH=""

  if [[ -f "${iso_path}" ]]; then
    info "Removing leftover partial file: ${iso_path}"
    rm -f "${iso_path}"
  fi

  info "Downloading ${filename}..."
  local curl_rc=0
  curl -fL --progress-bar -o "${iso_path}" "${base_url}/${filename}" || curl_rc=$?
  if [[ ${curl_rc} -ne 0 ]]; then
    error "Download failed (curl exit ${curl_rc})"
    rm -f "${iso_path}"
    return 1
  fi

  verify_checksum "${iso_path}" "${base_url}"
  DOWNLOADED_ISO_PATH="${iso_path}"
}

# ── Library item existence check ───────────────────────────────────────────────
library_item_exists() {
  local filename="$1"
  # govc library.ls returns exit 0 even for non-existent paths — check output
  [[ -n "$(govc library.ls "/${CONTENT_LIBRARY}/${filename}" 2>/dev/null)" ]]
}

# ── Import into Content Library ────────────────────────────────────────────────
import_iso() {
  local iso_path="$1"
  local filename; filename=$(basename "${iso_path}")

  info "Importing into Content Library '${CONTENT_LIBRARY}'..."
  info "  Size: $(du -sh "${iso_path}" | cut -f1)"

  govc library.import "${CONTENT_LIBRARY}" "${iso_path}"
  success "Imported: ${CONTENT_LIBRARY}/${filename}"
}

# ── Process a single version ───────────────────────────────────────────────────
process_version() {
  local version="$1"
  local label="${ISO_LABEL[${version}]:-Ubuntu ${version}}"
  local filename="${ISO_FILENAME[${version}]}"

  header "${label}"

  if library_item_exists "${filename}"; then
    success "Already present: ${CONTENT_LIBRARY}/${filename}"
    BUILD_STATUS[${version}]="SKIPPED (already present)"
    return 0
  fi
  info "Not found — will download and import"

  if ! download_iso "${version}"; then
    BUILD_STATUS[${version}]="FAILED"
    return 1
  fi

  local iso_path="${DOWNLOADED_ISO_PATH}"
  if [[ -z "${iso_path}" ]]; then
    error "No file path set after download"
    BUILD_STATUS[${version}]="FAILED"
    return 1
  fi

  import_iso "${iso_path}"
  BUILD_STATUS[${version}]="IMPORTED"

  if [[ "${KEEP_DOWNLOADS}" != "true" ]]; then
    rm -f "${iso_path}"
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
    [[ "${status}" == "IMPORTED" ]] && colour="${GREEN}"
    [[ "${status}" == SKIPPED*   ]] && colour="${YELLOW}"
    [[ "${status}" == "FAILED"*  ]] && colour="${RED}"
    printf "  %-8s  %-40s  ${colour}%s${RESET}\n" "${version}" "${filename}" "${status}"
  done
  echo ""
  info "Content Library : ${CONTENT_LIBRARY}"
  info "vCenter         : ${GOVC_URL}"
  echo ""
  echo -e "${BOLD}Secret to set (Settings → Secrets and variables → Actions):${RESET}"
  echo ""
  echo "  VSPHERE_ISO_LIBRARY_DATASTORE = \"${LIBRARY_DATASTORE}\""
  echo ""
  echo -e "${BOLD}Repository variable to set (Settings → Secrets and variables → Actions → Variables):${RESET}"
  echo ""
  echo "  CONTENT_LIBRARY = \"${CONTENT_LIBRARY}\""
  echo ""
  echo -e "ISO paths are resolved automatically at build time via:"
  echo -e "  govc library.info -L /${CONTENT_LIBRARY}/<item>/<file>"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}Packer ISO Uploader — vSphere Content Library${RESET}"
  echo -e "Versions: ${UBUNTU_VERSIONS}"
  echo ""

  check_prerequisites
  verify_govc_connection
  ensure_content_library
  mkdir -p "${DOWNLOAD_DIR}"

  local failed=0
  for version in ${UBUNTU_VERSIONS}; do
    process_version "${version}" || { BUILD_STATUS[${version}]="FAILED"; failed=1; }
  done

  print_summary

  [[ "${failed}" -eq 0 ]] || { error "One or more imports failed."; exit 1; }
  success "Done."
}

main "$@"

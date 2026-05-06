#!/usr/bin/env bash
# =============================================================================
# set-github-secrets.sh
# Reads variables.pkrvars.hcl and pushes every value to GitHub Actions secrets
# using the GitHub CLI (gh).
#
# Requirements:
#   gh   — https://cli.github.com  (must be authenticated: gh auth login)
#   git  — to detect the remote repo
#
# Usage (run from the repo root):
#   ./scripts/set-github-secrets.sh
#
# Options (environment variables):
#   VARS_FILE   — path to the pkrvars file (default: variables.pkrvars.hcl)
#   GH_REPO     — owner/repo override (default: auto-detected from git remote)
#   DRY_RUN     — set to "true" to print secrets without pushing them
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}==>${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✘${RESET}  $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──────────────────────────────────────────${RESET}"; }

# ── Config ────────────────────────────────────────────────────────────────────
VARS_FILE="${VARS_FILE:-variables.pkrvars.hcl}"
DRY_RUN="${DRY_RUN:-false}"

# ── Prerequisites ──────────────────────────────────────────────────────────────
check_prerequisites() {
  header "Checking prerequisites"

  local missing=0

  if ! command -v gh &>/dev/null; then
    error "gh (GitHub CLI) not found."
    echo "  Install: https://cli.github.com"
    echo "  Then authenticate: gh auth login"
    missing=1
  else
    success "gh found: $(gh --version | head -1)"
    if ! gh auth status &>/dev/null; then
      error "gh is not authenticated. Run: gh auth login"
      missing=1
    else
      success "gh is authenticated"
    fi
  fi

  if [[ ! -f "${VARS_FILE}" ]]; then
    error "Variables file not found: ${VARS_FILE}"
    echo "  Copy the example and fill in your values:"
    echo "  cp variables.pkrvars.hcl.example variables.pkrvars.hcl"
    missing=1
  else
    success "Variables file found: ${VARS_FILE}"
  fi

  [[ "${missing}" -eq 0 ]] || { error "Prerequisites not met — aborting."; exit 1; }
}

# ── Repo detection ─────────────────────────────────────────────────────────────
detect_repo() {
  if [[ -n "${GH_REPO:-}" ]]; then
    echo "${GH_REPO}"
    return
  fi

  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)

  if [[ -z "${remote_url}" ]]; then
    error "No git remote 'origin' found and GH_REPO is not set."
    echo "  Set it manually: GH_REPO=owner/repo ./scripts/set-github-secrets.sh"
    exit 1
  fi

  # Parse owner/repo from SSH or HTTPS remote URL
  local repo
  if [[ "${remote_url}" =~ github\.com[:/](.+/.+)(\.git)?$ ]]; then
    repo="${BASH_REMATCH[1]}"
    repo="${repo%.git}"
    echo "${repo}"
  else
    error "Could not parse GitHub owner/repo from remote: ${remote_url}"
    echo "  Set it manually: GH_REPO=owner/repo ./scripts/set-github-secrets.sh"
    exit 1
  fi
}

# ── HCL value parser ───────────────────────────────────────────────────────────
# Extracts the value for a given HCL key from the vars file.
# Handles: key = "string value"  and  key = bare_value
get_hcl_value() {
  local key="$1"
  local file="$2"

  local raw
  raw=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" | head -1 || true)

  if [[ -z "${raw}" ]]; then
    echo ""
    return
  fi

  # Strip key and equals sign
  local rhs
  rhs=$(echo "${raw}" | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" )

  # Remove trailing inline comments
  rhs=$(echo "${rhs}" | sed -E 's/[[:space:]]+#.*$//')

  # Strip surrounding double-quotes if present
  if [[ "${rhs}" =~ ^\"(.*)\"$ ]]; then
    rhs="${BASH_REMATCH[1]}"
  fi

  # Trim whitespace
  echo "${rhs}" | xargs
}

# ── Set a single secret ────────────────────────────────────────────────────────
set_secret() {
  local name="$1"
  local value="$2"
  local repo="$3"

  if [[ -z "${value}" ]]; then
    warn "Skipping ${name} — no value found in ${VARS_FILE}"
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    # Mask middle of value for safety in dry-run output
    local masked="${value:0:2}****${value: -2}"
    info "[DRY RUN] Would set ${name} = ${masked}"
    return
  fi

  # Use printf to avoid any shell interpretation of the value
  printf '%s' "${value}" | gh secret set "${name}" --repo "${repo}"
  success "Set ${name}"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}GitHub Secrets — Packer vSphere${RESET}"
  echo ""

  check_prerequisites

  header "Detecting repository"
  REPO=$(detect_repo)
  success "Target repository: ${REPO}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    warn "DRY RUN mode — secrets will be printed but not pushed"
  fi

  header "Reading ${VARS_FILE}"

  # ── Read all values from the pkrvars file ──────────────────────────────────
  VSPHERE_SERVER=$(get_hcl_value "vsphere_server" "${VARS_FILE}")
  VSPHERE_USER=$(get_hcl_value "vsphere_user" "${VARS_FILE}")
  VSPHERE_PASSWORD=$(get_hcl_value "vsphere_password" "${VARS_FILE}")
  VSPHERE_INSECURE=$(get_hcl_value "vsphere_insecure_connection" "${VARS_FILE}")
  VSPHERE_DATACENTER=$(get_hcl_value "vsphere_datacenter" "${VARS_FILE}")
  VSPHERE_CLUSTER=$(get_hcl_value "vsphere_cluster" "${VARS_FILE}")
  VSPHERE_HOST=$(get_hcl_value "vsphere_host" "${VARS_FILE}")
  VSPHERE_DATASTORE=$(get_hcl_value "vsphere_datastore" "${VARS_FILE}")
  VSPHERE_NETWORK=$(get_hcl_value "vsphere_network" "${VARS_FILE}")
  VSPHERE_FOLDER=$(get_hcl_value "vsphere_folder" "${VARS_FILE}")
  VSPHERE_ISO_DATASTORE=$(get_hcl_value "vsphere_iso_datastore" "${VARS_FILE}")
  BUILD_USERNAME=$(get_hcl_value "build_username" "${VARS_FILE}")
  BUILD_PASSWORD=$(get_hcl_value "build_password" "${VARS_FILE}")
  BUILD_PASSWORD_ENCRYPTED=$(get_hcl_value "build_password_encrypted" "${VARS_FILE}")
  UBUNTU_2204_ISO_PATH=$(get_hcl_value "ubuntu_2204_iso_path" "${VARS_FILE}")
  UBUNTU_2404_ISO_PATH=$(get_hcl_value "ubuntu_2404_iso_path" "${VARS_FILE}")
  UBUNTU_2604_ISO_PATH=$(get_hcl_value "ubuntu_2604_iso_path" "${VARS_FILE}")
  # Windows ISOs and credentials — only pushed when present in the vars file.
  WINDOWS_SERVER_2022_ISO=$(get_hcl_value "windows_server_2022_iso_path" "${VARS_FILE}")
  WINDOWS_SERVER_2025_ISO=$(get_hcl_value "windows_server_2025_iso_path" "${VARS_FILE}")
  WINDOWS_10_ISO=$(get_hcl_value "windows_10_iso_path" "${VARS_FILE}")
  WINDOWS_SERVER_2022_IMAGE_NAME=$(get_hcl_value "windows_server_2022_image_name" "${VARS_FILE}")
  WINDOWS_SERVER_2025_IMAGE_NAME=$(get_hcl_value "windows_server_2025_image_name" "${VARS_FILE}")
  WINDOWS_10_IMAGE_NAME=$(get_hcl_value "windows_10_image_name" "${VARS_FILE}")
  WINDOWS_ADMIN_PASSWORD=$(get_hcl_value "windows_admin_password" "${VARS_FILE}")
  WINDOWS_TIMEZONE=$(get_hcl_value "windows_timezone" "${VARS_FILE}")

  # VSPHERE_ISO_LIBRARY_DATASTORE is the backing datastore for the Content Library
  # (used by the upload-isos workflow). It defaults to vsphere_datastore if not set
  # separately. Add a line like:
  #   vsphere_iso_library_datastore = "datastore1"
  # to your vars file to override it.
  ISO_LIBRARY_DS=$(get_hcl_value "vsphere_iso_library_datastore" "${VARS_FILE}")
  if [[ -z "${ISO_LIBRARY_DS}" ]]; then
    ISO_LIBRARY_DS="${VSPHERE_DATASTORE}"
    info "vsphere_iso_library_datastore not set — defaulting to vsphere_datastore (${ISO_LIBRARY_DS})"
  fi

  success "Values parsed"

  # ── Push to GitHub ─────────────────────────────────────────────────────────
  header "Setting GitHub Actions secrets"

  set_secret "VSPHERE_SERVER"               "${VSPHERE_SERVER}"               "${REPO}"
  set_secret "VSPHERE_USER"                 "${VSPHERE_USER}"                 "${REPO}"
  set_secret "VSPHERE_PASSWORD"             "${VSPHERE_PASSWORD}"             "${REPO}"
  set_secret "VSPHERE_INSECURE"             "${VSPHERE_INSECURE}"             "${REPO}"
  set_secret "VSPHERE_DATACENTER"           "${VSPHERE_DATACENTER}"           "${REPO}"
  set_secret "VSPHERE_CLUSTER"              "${VSPHERE_CLUSTER}"              "${REPO}"
  set_secret "VSPHERE_HOST"                 "${VSPHERE_HOST}"                 "${REPO}"
  set_secret "VSPHERE_DATASTORE"            "${VSPHERE_DATASTORE}"            "${REPO}"
  set_secret "VSPHERE_NETWORK"              "${VSPHERE_NETWORK}"              "${REPO}"
  set_secret "VSPHERE_FOLDER"              "${VSPHERE_FOLDER}"               "${REPO}"
  set_secret "VSPHERE_ISO_DATASTORE"        "${VSPHERE_ISO_DATASTORE}"        "${REPO}"
  set_secret "VSPHERE_ISO_LIBRARY_DATASTORE" "${ISO_LIBRARY_DS}"             "${REPO}"
  set_secret "BUILD_USERNAME"               "${BUILD_USERNAME}"               "${REPO}"
  set_secret "BUILD_PASSWORD"               "${BUILD_PASSWORD}"               "${REPO}"
  set_secret "BUILD_PASSWORD_ENCRYPTED"     "${BUILD_PASSWORD_ENCRYPTED}"     "${REPO}"
  set_secret "UBUNTU_2204_ISO_PATH"         "${UBUNTU_2204_ISO_PATH}"         "${REPO}"
  set_secret "UBUNTU_2404_ISO_PATH"         "${UBUNTU_2404_ISO_PATH}"         "${REPO}"
  set_secret "UBUNTU_2604_ISO_PATH"         "${UBUNTU_2604_ISO_PATH}"         "${REPO}"
  # Windows secrets — set_secret skips entries with empty values so users who
  # never configure Windows in their vars file simply don't push these.
  set_secret "WINDOWS_SERVER_2022_ISO"        "${WINDOWS_SERVER_2022_ISO}"        "${REPO}"
  set_secret "WINDOWS_SERVER_2025_ISO"        "${WINDOWS_SERVER_2025_ISO}"        "${REPO}"
  set_secret "WINDOWS_10_ISO"                 "${WINDOWS_10_ISO}"                 "${REPO}"
  set_secret "WINDOWS_SERVER_2022_IMAGE_NAME" "${WINDOWS_SERVER_2022_IMAGE_NAME}" "${REPO}"
  set_secret "WINDOWS_SERVER_2025_IMAGE_NAME" "${WINDOWS_SERVER_2025_IMAGE_NAME}" "${REPO}"
  set_secret "WINDOWS_10_IMAGE_NAME"          "${WINDOWS_10_IMAGE_NAME}"          "${REPO}"
  set_secret "WINDOWS_ADMIN_PASSWORD"         "${WINDOWS_ADMIN_PASSWORD}"         "${REPO}"
  set_secret "WINDOWS_TIMEZONE"               "${WINDOWS_TIMEZONE}"               "${REPO}"

  # ── Summary ────────────────────────────────────────────────────────────────
  header "Summary"

  if [[ "${DRY_RUN}" != "true" ]]; then
    echo ""
    info "Verify at: https://github.com/${REPO}/settings/secrets/actions"
    echo ""
    success "All secrets pushed to ${REPO}"
  else
    echo ""
    warn "Dry run complete — no secrets were pushed."
    echo "  Remove DRY_RUN=true to push for real."
  fi
}

main "$@"

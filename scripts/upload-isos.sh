#!/usr/bin/env bash
# =============================================================================
# upload-isos.sh
# Downloads Ubuntu live-server ISOs (and, optionally, a curated set of extra
# homelab OS ISOs) and imports them into a vSphere Content Library using govc.
#
# Each ISO is processed serially: download → checksum (where available) →
# import → delete the local copy. The runner therefore only ever holds a
# single ISO on disk at once, regardless of how many are requested.
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
#   Pull a few extra OSes alongside Ubuntu:
#   EXTRA_ISOS="debian-12 rocky-9 alpine-3.21" ./scripts/upload-isos.sh
#
#   Pull every extra OS in the catalogue:
#   EXTRA_ISOS=all UBUNTU_VERSIONS="" ./scripts/upload-isos.sh
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
#   EXTRA_ISOS        — Space-separated slugs from the extras (default: "")
#                       catalogue, or "all". Run with no args
#                       and see the summary for the slug list.
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
EXTRA_ISOS="${EXTRA_ISOS:-}"
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

# ── Extras catalogue (opt-in via EXTRA_ISOS) ───────────────────────────────────
# Curated from Michael Cade's iso_contentlib.sh
# (https://github.com/MichaelCade/2025-vSphere-Homelab/blob/main/iso_contentlib.sh).
# Each slug maps to a local filename, a download URL, a human label, and
# (where the publisher offers a parseable SHA256SUMS / BSD-style CHECKSUM
# file) a checksum URL. Entries with an empty checksum URL download without
# verification — the script logs a clear warning when that happens.
#
# To add a new ISO: append to all four arrays under a fresh slug. To remove
# one: delete its line in each array. EXTRA_ISOS="all" iterates the slug
# list in EXTRA_ORDER below.
declare -A EXTRA_FILENAME=(
  [debian-12]="debian-12.9.0-amd64-netinst.iso"
  [debian-11-arm64]="debian-11.11.0-arm64-netinst.iso"
  [debian-12-live-kde]="debian-live-12.9.0-amd64-kde.iso"
  [rocky-9]="Rocky-9.5-x86_64-dvd.iso"
  [rocky-8]="Rocky-8.10-x86_64-dvd1.iso"
  [alma-9]="AlmaLinux-9.5-x86_64-dvd.iso"
  [alma-8]="AlmaLinux-8.10-x86_64-dvd.iso"
  [oracle-9]="OracleLinux-R9-U5-x86_64-dvd.iso"
  [oracle-8]="OracleLinux-R8-U10-x86_64-dvd.iso"
  [centos-stream-10]="CentOS-Stream-10-latest-x86_64-dvd1.iso"
  [centos-stream-9]="CentOS-Stream-9-latest-x86_64-dvd1.iso"
  [fedora-41-server]="Fedora-Server-dvd-x86_64-41-1.4.iso"
  [photon-5]="photon-5.0-dde71ec57.x86_64.iso"
  [photon-4]="photon-4.0-c001795b8.iso"
  [alpine-3.21]="alpine-virt-3.21.3-x86_64.iso"
  [arch]="archlinux-2025.03.01-x86_64.iso"
  [artix-plasma-dinit]="artix-plasma-dinit-20240823-x86_64.iso"
  [nixos-24.11-plasma]="nixos-24.11-plasma6-x86_64-linux.iso"
  [nixos-24.11-gnome]="nixos-24.11-gnome-x86_64-linux.iso"
  [kali-2024.4]="kali-linux-2024.4-installer-amd64.iso"
  [parrot-6.3.2]="Parrot-security-6.3.2_amd64.iso"
  [kubuntu-24.10]="kubuntu-24.10-desktop-amd64.iso"
  [lubuntu-24.04]="lubuntu-24.04.2-desktop-amd64.iso"
  [linuxmint-22.1]="linuxmint-22.1-cinnamon-64bit.iso"
  [solus-budgie]="Solus-Budgie-Release-2025-01-26.iso"
  [tinycore-15]="CorePlus-current.iso"
  [windows-server-2025-eval]="windows-server-2025-eval.iso"
  [windows-server-2022-eval]="windows-server-2022-eval.iso"
  [windows-server-2019-eval]="windows-server-2019-eval.iso"
  [windows-11-enterprise-eval]="windows-11-enterprise-eval.iso"
  [windows-10-enterprise-eval]="windows-10-enterprise-eval.iso"
)

declare -A EXTRA_URL=(
  [debian-12]="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso"
  [debian-11-arm64]="https://cdimage.debian.org/cdimage/archive/11.11.0/arm64/iso-cd/debian-11.11.0-arm64-netinst.iso"
  [debian-12-live-kde]="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.9.0-amd64-kde.iso"
  [rocky-9]="https://download.rockylinux.org/pub/rocky/9.5/isos/x86_64/Rocky-9.5-x86_64-dvd.iso"
  [rocky-8]="https://download.rockylinux.org/pub/rocky/8.10/isos/x86_64/Rocky-8.10-x86_64-dvd1.iso"
  [alma-9]="https://repo.almalinux.org/almalinux/9.5/isos/x86_64/AlmaLinux-9.5-x86_64-dvd.iso"
  [alma-8]="https://repo.almalinux.org/almalinux/8.10/isos/x86_64/AlmaLinux-8.10-x86_64-dvd.iso"
  [oracle-9]="https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/x86_64/OracleLinux-R9-U5-x86_64-dvd.iso"
  [oracle-8]="https://yum.oracle.com/ISOS/OracleLinux/OL8/u10/x86_64/OracleLinux-R8-U10-x86_64-dvd.iso"
  [centos-stream-10]="https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/iso/CentOS-Stream-10-latest-x86_64-dvd1.iso"
  [centos-stream-9]="https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/iso/CentOS-Stream-9-latest-x86_64-dvd1.iso"
  [fedora-41-server]="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Server/x86_64/iso/Fedora-Server-dvd-x86_64-41-1.4.iso"
  [photon-5]="https://packages.vmware.com/photon/5.0/GA/iso/photon-5.0-dde71ec57.x86_64.iso"
  [photon-4]="https://packages.vmware.com/photon/4.0/Rev2/iso/photon-4.0-c001795b8.iso"
  [alpine-3.21]="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-virt-3.21.3-x86_64.iso"
  [arch]="https://archlinux.uk.mirror.allworldit.com/archlinux/iso/2025.03.01/archlinux-2025.03.01-x86_64.iso"
  [artix-plasma-dinit]="https://iso.artixlinux.org/iso/artix-plasma-dinit-20240823-x86_64.iso"
  [nixos-24.11-plasma]="https://channels.nixos.org/nixos-24.11/latest-nixos-plasma6-x86_64-linux.iso"
  [nixos-24.11-gnome]="https://channels.nixos.org/nixos-24.11/latest-nixos-gnome-x86_64-linux.iso"
  [kali-2024.4]="https://cdimage.kali.org/kali-2024.4/kali-linux-2024.4-installer-amd64.iso"
  [parrot-6.3.2]="https://deb.parrot.sh/parrot/iso/6.3.2/Parrot-security-6.3.2_amd64.iso"
  [kubuntu-24.10]="https://cdimage.ubuntu.com/kubuntu/releases/24.10/release/kubuntu-24.10-desktop-amd64.iso"
  [lubuntu-24.04]="https://cdimage.ubuntu.com/lubuntu/releases/noble/release/lubuntu-24.04.2-desktop-amd64.iso"
  [linuxmint-22.1]="https://mirrors.cicku.me/linuxmint/iso/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
  [solus-budgie]="https://downloads.getsol.us/isos/2025-01-26/Solus-Budgie-Release-2025-01-26.iso"
  [tinycore-15]="https://distro.ibiblio.org/tinycorelinux/15.x/x86/release/CorePlus-current.iso"
  [windows-server-2025-eval]="https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
  [windows-server-2022-eval]="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
  [windows-server-2019-eval]="https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66749/17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
  [windows-11-enterprise-eval]="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/22631.2428.231001-0608.23H2_NI_RELEASE_SVC_REFRESH_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
  [windows-10-enterprise-eval]="https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
)

declare -A EXTRA_LABEL=(
  [debian-12]="Debian 12.9.0 (Bookworm, amd64 netinst)"
  [debian-11-arm64]="Debian 11.11.0 (Bullseye, arm64 netinst)"
  [debian-12-live-kde]="Debian Live 12.9.0 (KDE, amd64)"
  [rocky-9]="Rocky Linux 9.5 (x86_64 DVD)"
  [rocky-8]="Rocky Linux 8.10 (x86_64 DVD)"
  [alma-9]="AlmaLinux 9.5 (x86_64 DVD)"
  [alma-8]="AlmaLinux 8.10 (x86_64 DVD)"
  [oracle-9]="Oracle Linux 9 Update 5 (x86_64 DVD)"
  [oracle-8]="Oracle Linux 8 Update 10 (x86_64 DVD)"
  [centos-stream-10]="CentOS Stream 10 (x86_64 DVD, latest)"
  [centos-stream-9]="CentOS Stream 9 (x86_64 DVD, latest)"
  [fedora-41-server]="Fedora Server 41 (x86_64 DVD)"
  [photon-5]="VMware Photon OS 5.0 GA (x86_64)"
  [photon-4]="VMware Photon OS 4.0 Rev2 (x86_64)"
  [alpine-3.21]="Alpine Linux 3.21.3 (virt, x86_64)"
  [arch]="Arch Linux 2025.03.01 (x86_64)"
  [artix-plasma-dinit]="Artix Linux Plasma (dinit, 2024-08-23, x86_64)"
  [nixos-24.11-plasma]="NixOS 24.11 (Plasma 6, x86_64)"
  [nixos-24.11-gnome]="NixOS 24.11 (GNOME, x86_64)"
  [kali-2024.4]="Kali Linux 2024.4 (installer, amd64)"
  [parrot-6.3.2]="Parrot Security 6.3.2 (amd64)"
  [kubuntu-24.10]="Kubuntu 24.10 (desktop, amd64)"
  [lubuntu-24.04]="Lubuntu 24.04.2 (desktop, amd64)"
  [linuxmint-22.1]="Linux Mint 22.1 (Cinnamon, 64-bit)"
  [solus-budgie]="Solus Budgie (2025-01-26)"
  [tinycore-15]="Tiny Core Linux 15.x (CorePlus, current)"
  [windows-server-2025-eval]="Windows Server 2025 Evaluation (x64)"
  [windows-server-2022-eval]="Windows Server 2022 Evaluation (x64)"
  [windows-server-2019-eval]="Windows Server 2019 Evaluation (x64)"
  [windows-11-enterprise-eval]="Windows 11 Enterprise Evaluation (x64, 23H2)"
  [windows-10-enterprise-eval]="Windows 10 Enterprise Evaluation (x64, 22H2)"
)

# Checksum URLs are populated only where the publisher exposes a SHA256SUMS
# (or BSD-style CHECKSUM) file that lists the ISO's filename verbatim.
# Entries left empty intentionally — the script downloads without verification
# and prints a warning, matching the behaviour Cade's reference script has.
declare -A EXTRA_CHECKSUM_URL=(
  [debian-12]="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
  [debian-11-arm64]="https://cdimage.debian.org/cdimage/archive/11.11.0/arm64/iso-cd/SHA256SUMS"
  [debian-12-live-kde]="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS"
  [rocky-9]=""
  [rocky-8]=""
  [alma-9]=""
  [alma-8]=""
  [oracle-9]=""
  [oracle-8]=""
  [centos-stream-10]=""
  [centos-stream-9]=""
  [fedora-41-server]=""
  [photon-5]=""
  [photon-4]=""
  [alpine-3.21]="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-virt-3.21.3-x86_64.iso.sha256"
  [arch]=""
  [artix-plasma-dinit]=""
  [nixos-24.11-plasma]=""
  [nixos-24.11-gnome]=""
  [kali-2024.4]="https://cdimage.kali.org/kali-2024.4/SHA256SUMS"
  [parrot-6.3.2]=""
  [kubuntu-24.10]="https://cdimage.ubuntu.com/kubuntu/releases/24.10/release/SHA256SUMS"
  [lubuntu-24.04]="https://cdimage.ubuntu.com/lubuntu/releases/noble/release/SHA256SUMS"
  [linuxmint-22.1]=""
  [solus-budgie]=""
  [tinycore-15]=""
  [windows-server-2025-eval]=""
  [windows-server-2022-eval]=""
  [windows-server-2019-eval]=""
  [windows-11-enterprise-eval]=""
  [windows-10-enterprise-eval]=""
)

# Iteration order for EXTRA_ISOS="all". Newest / most-common first so a
# partial run still grabs the useful stuff before any wonky URL fails.
EXTRA_ORDER=(
  debian-12 debian-11-arm64 debian-12-live-kde
  rocky-9 rocky-8 alma-9 alma-8 oracle-9 oracle-8
  centos-stream-10 centos-stream-9 fedora-41-server
  photon-5 photon-4 alpine-3.21 arch artix-plasma-dinit
  nixos-24.11-plasma nixos-24.11-gnome
  kali-2024.4 parrot-6.3.2
  kubuntu-24.10 lubuntu-24.04 linuxmint-22.1 solus-budgie tinycore-15
  windows-server-2025-eval windows-server-2022-eval windows-server-2019-eval
  windows-11-enterprise-eval windows-10-enterprise-eval
)

declare -A BUILD_STATUS=()
declare -A EXTRA_STATUS=()
DOWNLOADED_ISO_PATH=""
EXTRA_SELECTED=()

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

  mkdir -p "${DOWNLOAD_DIR}"

  # When we're not keeping downloads, DOWNLOAD_DIR is meant to be transient —
  # it should only ever hold the single in-flight ISO. Purge any *.iso left
  # behind by a previous crashed/cancelled run so stale files don't eat into
  # the space check below (or the runner's disk).
  if [[ "${KEEP_DOWNLOADS}" != "true" ]]; then
    local stale
    while IFS= read -r stale; do
      [[ -n "${stale}" ]] || continue
      info "Removing stale download from a previous run: $(basename "${stale}")"
      rm -f "${stale}"
    done < <(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -name '*.iso' 2>/dev/null)
  fi

  # Size the disk requirement from the actual Content-Length of the ISOs this
  # run will fetch, rather than a catalogue-wide worst case — so a Windows-only
  # or netinst-only run isn't blocked by the size of a full DVD it never touches.
  local urls=() v s
  for v in ${UBUNTU_VERSIONS}; do
    [[ -n "${ISO_FILENAME[${v}]:-}" ]] && urls+=("${ISO_BASE_URL[${v}]}/${ISO_FILENAME[${v}]}")
  done
  for s in "${EXTRA_SELECTED[@]}"; do
    [[ -n "${EXTRA_URL[${s}]:-}" ]] && urls+=("${EXTRA_URL[${s}]}")
  done

  local fallback_bytes=$(( 14 * 1024 * 1024 * 1024 ))  # unknown size → assume a full DVD
  local max_bytes=0 total_bytes=0 b u
  for u in "${urls[@]}"; do
    b=$(curl -sIL --connect-timeout 10 --max-time 30 "${u}" 2>/dev/null \
         | awk -F': ' 'tolower($1)=="content-length"{n=$2} END{gsub(/\r/,"",n); print n+0}')
    { [[ "${b}" =~ ^[0-9]+$ ]] && [[ "${b}" -gt 0 ]]; } || b=${fallback_bytes}
    if (( b > max_bytes )); then max_bytes=${b}; fi
    total_bytes=$(( total_bytes + b ))
  done

  # ~2 GB headroom for the checksum sidecar, govc temp, and rounding.
  local required_gb
  if [[ "${KEEP_DOWNLOADS}" == "true" ]]; then
    required_gb=$(( total_bytes / 1024 / 1024 / 1024 + 2 ))   # everything kept → sum
  else
    required_gb=$(( max_bytes / 1024 / 1024 / 1024 + 2 ))     # one at a time → largest
  fi
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

# ── Hardened HTTP fetch ────────────────────────────────────────────────────────
# Wraps curl so a transient stall on the runner's egress (or a flaky mirror)
# doesn't kill the whole job. The earlier failure mode was:
#   "curl: (28) Connection timed out after 300286 milliseconds"
# i.e. a half-open connection that printed a few progress dashes then sat
# for 5 minutes with no data. Without retry/--speed-time the script just
# burned the default connect-timeout and quit.
#
# Watchdog:
#   --connect-timeout 30      fail fast at the TCP/TLS handshake
#   --speed-limit 102400      "below 100 KB/s..."
#   --speed-time 60           "...for 60s = abort this attempt"
#   --retry 5 --retry-delay 15
#   --retry-all-errors        treat ANY failure (not just 5xx) as retryable
#   --retry-max-time 1800     give up after 30 min wall-clock
#   -C -                      resume from byte offset between retries
#
# Args: $1=output path, $2=URL, $3="progress"|"quiet" (default quiet)
download_with_retries() {
  local out="$1" url="$2" mode="${3:-quiet}"
  local progress_opts=(-sS)
  [[ "${mode}" == "progress" ]] && progress_opts=(--progress-bar)

  curl -fL "${progress_opts[@]}" \
    --retry 5 --retry-delay 15 --retry-all-errors --retry-max-time 1800 \
    --connect-timeout 30 \
    --speed-limit 102400 --speed-time 60 \
    -C - \
    -o "${out}" "${url}"
}

# Best-effort dump of why the runner can't reach a host. Surfaces whether
# the failure is DNS, TCP, TLS, or HTTP-layer — much faster to act on than
# a bare "exit 28".
diagnose_connectivity() {
  local url="$1"
  local host
  host=$(printf '%s' "${url}" | awk -F/ '{print $3}')
  warn "Connectivity diagnostic for https://${host}"
  printf '    DNS:           '
  if command -v getent &>/dev/null; then
    getent hosts "${host}" | head -1 || echo "FAIL"
  else
    host "${host}" 2>/dev/null | head -1 || echo "FAIL"
  fi
  printf '    TCP/443 probe: '
  if timeout 5 bash -c ">/dev/tcp/${host}/443" 2>/dev/null; then
    echo "OK"
  else
    echo "FAIL (no TCP path to ${host}:443 within 5s)"
  fi
  printf '    HTTP HEAD:     '
  curl -sS -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
    --connect-timeout 5 --max-time 10 -I "https://${host}/" \
    || echo "FAIL"
}

# ── Checksum ───────────────────────────────────────────────────────────────────
# Verifies $iso_file against a SHA256 listed at $checksum_url. Handles three
# real-world formats so the same function works for Ubuntu, Debian, Kali
# (standard `<hash>  [*]filename` SHA256SUMS), Alpine-style sidecar files
# (`<hash>  filename` — one line), and any future publisher that uses the
# BSD-style `SHA256 (filename) = <hash>` layout.
#
# Empty $checksum_url means "no published checksum file" — warn and return
# success so the rest of the pipeline can decide what to do (matches the
# graceful-degrade behaviour for SHA256SUMS files that don't list every
# basename).
verify_checksum() {
  local iso_file="$1" checksum_url="$2"
  local filename; filename=$(basename "${iso_file}")

  if [[ "${SKIP_CHECKSUM}" == "true" ]]; then
    warn "Checksum verification skipped"
    return 0
  fi

  if [[ -z "${checksum_url}" ]]; then
    warn "No checksum URL configured for ${filename} — skipping verification"
    return 0
  fi

  info "Downloading checksum file..."
  local sums_file="${DOWNLOAD_DIR}/SHA256SUMS.${filename}"
  if ! download_with_retries "${sums_file}" "${checksum_url}"; then
    error "Could not fetch checksum file from ${checksum_url}"
    diagnose_connectivity "${checksum_url}"
    return 1
  fi

  # Standard format: "<hash>  filename" or "<hash>  *filename"
  local expected_hash
  expected_hash=$(grep -E " \*?${filename}\$" "${sums_file}" | awk '{print $1}' | head -1)

  # BSD format fallback: "SHA256 (filename) = <hash>"
  if [[ -z "${expected_hash}" ]]; then
    expected_hash=$(grep -E "\(${filename}\)" "${sums_file}" \
      | awk -F'= ' '{print $2}' | awk '{print $1}' | head -1)
  fi

  if [[ -z "${expected_hash}" ]]; then
    warn "Checksum for '${filename}' not found in checksum file — skipping"
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
  download_with_retries "${iso_path}" "${base_url}/${filename}" progress || curl_rc=$?
  if [[ ${curl_rc} -ne 0 ]]; then
    error "Download failed (curl exit ${curl_rc}) after retries"
    diagnose_connectivity "${base_url}/${filename}"
    rm -f "${iso_path}"
    return 1
  fi

  if ! verify_checksum "${iso_path}" "${base_url}/SHA256SUMS"; then
    rm -f "${iso_path}"
    return 1
  fi
  DOWNLOADED_ISO_PATH="${iso_path}"
}

# ── Extras: download → verify → import → delete (per ISO) ──────────────────────
# Same strict serial pattern as Ubuntu — only one ISO ever lives on disk.
# Each step in here can fail independently; on any failure we mark the slug
# FAILED and move on so a single broken URL doesn't kill the whole batch.
download_extra() {
  local slug="$1"
  local filename="${EXTRA_FILENAME[${slug}]}"
  local url="${EXTRA_URL[${slug}]}"
  local iso_path="${DOWNLOAD_DIR}/${filename}"

  DOWNLOADED_ISO_PATH=""

  if [[ -f "${iso_path}" ]]; then
    info "Removing leftover partial file: ${iso_path}"
    rm -f "${iso_path}"
  fi

  info "Downloading ${filename}..."
  local curl_rc=0
  download_with_retries "${iso_path}" "${url}" progress || curl_rc=$?
  if [[ ${curl_rc} -ne 0 ]]; then
    error "Download failed (curl exit ${curl_rc}) after retries"
    diagnose_connectivity "${url}"
    rm -f "${iso_path}"
    return 1
  fi

  if ! verify_checksum "${iso_path}" "${EXTRA_CHECKSUM_URL[${slug}]:-}"; then
    rm -f "${iso_path}"
    return 1
  fi
  DOWNLOADED_ISO_PATH="${iso_path}"
}

process_extra() {
  local slug="$1"
  if [[ -z "${EXTRA_FILENAME[${slug}]+x}" ]]; then
    error "Unknown extra ISO slug: '${slug}' — see the summary table for valid slugs"
    EXTRA_STATUS[${slug}]="FAILED (unknown slug)"
    return 1
  fi

  local label="${EXTRA_LABEL[${slug}]}"
  local filename="${EXTRA_FILENAME[${slug}]}"

  header "${label}"

  if library_item_exists "${filename}"; then
    success "Already present: ${CONTENT_LIBRARY}/${filename}"
    EXTRA_STATUS[${slug}]="SKIPPED (already present)"
    return 0
  fi
  info "Not found — will download and import"

  if ! download_extra "${slug}"; then
    EXTRA_STATUS[${slug}]="FAILED"
    return 1
  fi

  local iso_path="${DOWNLOADED_ISO_PATH}"
  if [[ -z "${iso_path}" ]]; then
    error "No file path set after download"
    EXTRA_STATUS[${slug}]="FAILED"
    return 1
  fi

  local import_rc=0
  import_iso "${iso_path}" || import_rc=$?

  # Clean up the local copy whether the import succeeded or failed, so a
  # failed import doesn't leave a multi-GB ISO stranded on the runner during
  # a long serial batch. KEEP_DOWNLOADS=true opts out (e.g. uploading to
  # multiple vCenters).
  if [[ "${KEEP_DOWNLOADS}" != "true" ]]; then
    rm -f "${iso_path}"
  fi

  if [[ ${import_rc} -ne 0 ]]; then
    EXTRA_STATUS[${slug}]="FAILED"
    return 1
  fi
  EXTRA_STATUS[${slug}]="IMPORTED"
}

# Expands "all" into EXTRA_ORDER, leaves explicit slug lists untouched, and
# trims duplicates so a user passing the same slug twice doesn't get two
# library-exists checks. Sets EXTRA_SELECTED as the final ordered list.
resolve_extras_selection() {
  EXTRA_SELECTED=()
  [[ -z "${EXTRA_ISOS}" ]] && return 0

  local requested=()
  if [[ "${EXTRA_ISOS}" == "all" ]]; then
    requested=("${EXTRA_ORDER[@]}")
  else
    # shellcheck disable=SC2206
    requested=( ${EXTRA_ISOS} )
  fi

  local seen=()
  local slug
  for slug in "${requested[@]}"; do
    [[ " ${seen[*]} " == *" ${slug} "* ]] && continue
    seen+=("${slug}")
    EXTRA_SELECTED+=("${slug}")
  done
}

# ── Library item existence check ───────────────────────────────────────────────
library_item_exists() {
  local filename="$1"
  # govc names the library *item* after the file's basename with the
  # extension stripped (e.g. "ubuntu-26.04-live-server-amd64.iso" becomes
  # the item "ubuntu-26.04-live-server-amd64"), so we must check for that
  # item name, not the raw filename — otherwise the check never matches, the
  # ISO is re-downloaded, and govc rejects the re-import with already_exists.
  # govc library.ls returns exit 0 even for non-existent paths — check output.
  local item="${filename%.iso}"
  [[ -n "$(govc library.ls "/${CONTENT_LIBRARY}/${item}" 2>/dev/null)" ]]
}

# ── Import into Content Library ────────────────────────────────────────────────
import_iso() {
  local iso_path="$1"
  local filename; filename=$(basename "${iso_path}")

  info "Importing into Content Library '${CONTENT_LIBRARY}'..."
  info "  Size: $(du -sh "${iso_path}" | cut -f1)"

  if ! govc library.import "${CONTENT_LIBRARY}" "${iso_path}"; then
    error "Import failed: ${CONTENT_LIBRARY}/${filename}"
    return 1
  fi
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

  local import_rc=0
  import_iso "${iso_path}" || import_rc=$?

  # Clean up the local copy whether the import succeeded or failed, so a
  # failed import doesn't leave a multi-GB ISO stranded on the runner.
  # KEEP_DOWNLOADS=true opts out (e.g. uploading to multiple vCenters).
  if [[ "${KEEP_DOWNLOADS}" != "true" ]]; then
    rm -f "${iso_path}"
  fi

  if [[ ${import_rc} -ne 0 ]]; then
    BUILD_STATUS[${version}]="FAILED"
    return 1
  fi
  BUILD_STATUS[${version}]="IMPORTED"
}

# ── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
  header "Summary"
  echo ""
  if [[ -n "${UBUNTU_VERSIONS// }" ]]; then
    printf "  %-8s  %-50s  %s\n" "VERSION" "ISO" "STATUS"
    printf "  %-8s  %-50s  %s\n" "-------" "---" "------"
    for version in ${UBUNTU_VERSIONS}; do
      local filename="${ISO_FILENAME[${version}]:-N/A}"
      local status="${BUILD_STATUS[${version}]:-NOT PROCESSED}"
      local colour="${RESET}"
      [[ "${status}" == "IMPORTED" ]] && colour="${GREEN}"
      [[ "${status}" == SKIPPED*   ]] && colour="${YELLOW}"
      [[ "${status}" == "FAILED"*  ]] && colour="${RED}"
      printf "  %-8s  %-50s  ${colour}%s${RESET}\n" "${version}" "${filename}" "${status}"
    done
    echo ""
  fi

  if [[ ${#EXTRA_SELECTED[@]} -gt 0 ]]; then
    printf "  %-28s  %-50s  %s\n" "EXTRA SLUG" "ISO" "STATUS"
    printf "  %-28s  %-50s  %s\n" "----------" "---" "------"
    local slug
    for slug in "${EXTRA_SELECTED[@]}"; do
      local filename="${EXTRA_FILENAME[${slug}]:-N/A}"
      local status="${EXTRA_STATUS[${slug}]:-NOT PROCESSED}"
      local colour="${RESET}"
      [[ "${status}" == "IMPORTED" ]] && colour="${GREEN}"
      [[ "${status}" == SKIPPED*   ]] && colour="${YELLOW}"
      [[ "${status}" == FAILED*    ]] && colour="${RED}"
      printf "  %-28s  %-50s  ${colour}%s${RESET}\n" "${slug}" "${filename}" "${status}"
    done
    echo ""
  fi

  if [[ ${#EXTRA_SELECTED[@]} -eq 0 ]]; then
    info "Extras catalogue available (set EXTRA_ISOS to opt in):"
    printf '    %s\n' "${EXTRA_ORDER[*]}" | fold -sw 72 | sed 's/^/    /'
    echo ""
  fi

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
  echo -e "Ubuntu versions : ${UBUNTU_VERSIONS:-(none)}"
  echo -e "Extra ISOs      : ${EXTRA_ISOS:-(none)}"
  echo ""

  # Resolve extras up-front so prerequisites can size disk correctly and
  # bad slugs fail fast — before we spend time on vSphere round-trips.
  resolve_extras_selection
  if [[ -n "${EXTRA_ISOS}" && ${#EXTRA_SELECTED[@]} -eq 0 ]]; then
    error "EXTRA_ISOS was set but resolved to an empty selection."
    exit 1
  fi

  check_prerequisites
  verify_govc_connection
  ensure_content_library
  mkdir -p "${DOWNLOAD_DIR}"

  local failed=0
  for version in ${UBUNTU_VERSIONS}; do
    process_version "${version}" || { BUILD_STATUS[${version}]="FAILED"; failed=1; }
  done

  local slug
  for slug in "${EXTRA_SELECTED[@]}"; do
    process_extra "${slug}" || { EXTRA_STATUS[${slug}]="FAILED"; failed=1; }
  done

  print_summary

  [[ "${failed}" -eq 0 ]] || { error "One or more imports failed."; exit 1; }
  success "Done."
}

main "$@"

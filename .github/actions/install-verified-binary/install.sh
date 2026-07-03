#!/usr/bin/env bash
# =============================================================================
# install-verified-binary — download + SHA256-verify + install govc or packer.
#
# Best-effort fallback used by the CI workflows when the runner isn't
# pre-provisioned with the tool (see docs/operations.md → Setting up the
# runner). Called via the composite action.yml alongside this script, which
# passes TOOL and (optionally) PIN_VERSION in the environment.
#
# Why this exists: the previous inline install blocks piped an unpinned
# `releases/latest` tarball straight into `sudo tar` / `sudo mv` with no
# integrity check — a corrupted or MITM'd download body would be installed to
# /usr/local/bin and run as part of the pipeline. This resolves the version
# (pinned or latest), fetches the publisher's own checksums file over a
# separate HTTPS request, verifies the archive against it, and only then runs
# sudo. Pin PIN_VERSION for the stronger guarantee (an upstream release being
# replaced in place); the checksum step already covers a tampered download at
# a given version.
#
# gh / cloud-init / pre-commit are intentionally NOT handled here — they
# install via apt (GPG-signed repo) or pip (PyPI), which are already verified.
# =============================================================================
set -euo pipefail

TOOL="${TOOL:?TOOL must be set (govc|packer)}"
PIN_VERSION="${PIN_VERSION:-}"

if command -v "${TOOL}" &>/dev/null; then
  echo "${TOOL} already installed: $(${TOOL} version 2>/dev/null | head -1 || true)"
  exit 0
fi

echo "${TOOL} not installed — best-effort verified auto-install (requires sudo)."
echo "If this fails, pre-install per docs/operations.md → Setting up the runner."

arch_dpkg=$(dpkg --print-architecture)   # amd64 / arm64
workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
cd "${workdir}"

case "${TOOL}" in
  packer)
    version="${PIN_VERSION}"
    if [[ -z "${version}" ]]; then
      version=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/packer/latest \
        | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    [[ -n "${version}" ]] || { echo "✘ could not resolve a packer version" >&2; exit 1; }
    archive="packer_${version}_linux_${arch_dpkg}.zip"
    base="https://releases.hashicorp.com/packer/${version}"
    curl -fsSL "${base}/${archive}" -o "${archive}"
    curl -fsSL "${base}/packer_${version}_SHA256SUMS" -o SUMS
    ;;
  govc)
    version="${PIN_VERSION}"
    if [[ -z "${version}" ]]; then
      version=$(curl -fsSL https://api.github.com/repos/vmware/govmomi/releases/latest \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    fi
    [[ -n "${version}" ]] || { echo "✘ could not resolve a govc version" >&2; exit 1; }
    # govc release assets use uname-style arch (x86_64 / arm64), not dpkg's.
    case "${arch_dpkg}" in
      amd64) uarch=x86_64 ;;
      arm64) uarch=arm64 ;;
      *)     uarch="${arch_dpkg}" ;;
    esac
    archive="govc_Linux_${uarch}.tar.gz"
    base="https://github.com/vmware/govmomi/releases/download/${version}"
    curl -fsSL "${base}/${archive}" -o "${archive}"
    curl -fsSL "${base}/checksums.txt" -o SUMS
    ;;
  *)
    echo "✘ unsupported tool: ${TOOL} (expected govc or packer)" >&2
    exit 2
    ;;
esac

echo "Verifying ${archive} (version ${version}) against the published SHA256..."
# Keep only the checksums line for our archive and let sha256sum -c fail the
# job on any mismatch. Two spaces between hash and filename is the standard
# emitted by both HashiCorp's SHA256SUMS and GoReleaser's checksums.txt.
if ! grep -E "  ${archive}\$" SUMS | sha256sum -c --strict -; then
  echo "✘ checksum verification failed for ${archive} — refusing to install." >&2
  exit 1
fi
echo "✔ checksum OK"

case "${archive}" in
  *.zip)    python3 -c "import zipfile; zipfile.ZipFile('${archive}').extractall('.')" ;;
  *.tar.gz) tar -xzf "${archive}" ;;
esac

sudo install -m 0755 "${TOOL}" /usr/local/bin/"${TOOL}"
echo "${TOOL} installed: $(${TOOL} version 2>/dev/null | head -1 || echo ok)"

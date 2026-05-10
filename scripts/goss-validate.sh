#!/usr/bin/env bash
# =============================================================================
# goss-validate.sh — Run a Goss smoke-test spec against the in-flight VM.
#
# Runs as the LAST provisioner step (after setup.sh / desktop.sh / vmtools.sh)
# so the assertions match the actual state Packer is about to convert to a
# template. If goss fails, the build fails and pruning never runs — a broken
# template cannot replace a good one.
#
# Required environment variables:
#   GOSS_SPEC        — path to the goss spec file inside the VM
#                      (uploaded by a Packer file provisioner immediately
#                      before this script runs)
#   BUILD_USERNAME   — the OS user created by autoinstall, threaded through
#                      so goss can assert on `/etc/sudoers.d/90-packer-<user>`
#
# Optional:
#   GOSS_VERSION     — pinned goss release tag; bump deliberately
#                      (default: v0.4.9)
# =============================================================================
set -euo pipefail

GOSS_VERSION="${GOSS_VERSION:-v0.4.9}"
GOSS_BIN="/usr/local/bin/goss"
GOSS_SPEC="${GOSS_SPEC:?GOSS_SPEC env var must point at the spec file}"
BUILD_USERNAME="${BUILD_USERNAME:?BUILD_USERNAME env var must be set}"

if [[ ! -f "${GOSS_SPEC}" ]]; then
  echo "==> Goss spec not found at ${GOSS_SPEC}" >&2
  exit 1
fi

# ── Install goss (skipped if already present from a previous attempt) ──
if ! command -v goss >/dev/null 2>&1; then
  echo "==> Installing goss ${GOSS_VERSION}..."
  arch=$(dpkg --print-architecture)
  case "${arch}" in
    amd64) goss_arch="amd64" ;;
    arm64) goss_arch="arm64" ;;
    *) echo "Unsupported arch: ${arch}" >&2; exit 1 ;;
  esac
  curl -fsSL \
    "https://github.com/goss-org/goss/releases/download/${GOSS_VERSION}/goss-linux-${goss_arch}" \
    -o "${GOSS_BIN}"
  chmod +x "${GOSS_BIN}"
fi

echo "==> Running goss validate against ${GOSS_SPEC}..."
echo "    build_username = ${BUILD_USERNAME}"
echo ""

# --vars-inline passes a JSON object that becomes `.Vars.*` in the spec's
# Go-templated fields (e.g. `.Vars.build_username`).
goss \
  --vars-inline "{\"build_username\":\"${BUILD_USERNAME}\"}" \
  --gossfile "${GOSS_SPEC}" \
  validate \
  --color \
  --format documentation

rc=$?

# ── Clean up so the binary and spec don't ship in the template ──
echo ""
echo "==> Cleaning up goss artefacts..."
rm -f "${GOSS_BIN}" "${GOSS_SPEC}"

if [[ ${rc} -eq 0 ]]; then
  echo "==> goss-validate.sh complete — all assertions passed."
else
  echo "==> goss-validate.sh FAILED — build will abort." >&2
fi
exit "${rc}"

#!/usr/bin/env bash
# =============================================================================
# lint-user-data.sh
# Renders each templates/*-user-data.pkrtpl with placeholder values and pipes
# the result through `cloud-init schema --config-file -` to catch cloud-config
# syntax errors at PR time.
#
# Without this, the only validator for the user-data is the actual install:
# we wouldn't see a malformed `network:` or an un-nested netplan key until
# subiquity choked on it 5-15 minutes into a real Packer build. This step
# catches that class of bug in ~1 second of CI runner time, with no vSphere
# contact.
#
# What we render:
#   - templates/server-user-data.pkrtpl
#   - templates/desktop-user-data.pkrtpl
#
# What we substitute (matches the templatefile() call sites in ubuntu-*.pkr.hcl):
#   ${vm_hostname}                                  → lint-host
#   ${build_username}                               → lintuser
#   ${build_password_encrypted}                     → $6$rounds=4096$salt$hash...
#   ${jsonencode(build_ssh_authorized_keys)}        → ["ssh-ed25519 AAAA... lint"]
#   ${locale}                                       → en_GB.UTF-8
#   ${keyboard_layout}                              → gb
#   ${timezone}                                     → Europe/London
#
# Placeholders are chosen so the rendered output is a valid cloud-config the
# schema can accept — the assertion is about the template's STRUCTURE, not
# about the runtime values.
#
# Requires:
#   - python3 (for the rendering — no Jinja, just a small re.sub)
#   - cloud-init (provides the `cloud-init` CLI; `cloud-init schema` is part
#     of the package). Pre-installed on the runner per docs/operations.md.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${REPO_ROOT}/templates"

if ! command -v cloud-init >/dev/null 2>&1; then
  echo "❌ cloud-init not on PATH."
  echo "   Install via: sudo apt-get install -y cloud-init"
  echo "   (Also documented in docs/operations.md — runner pre-install list.)"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 not on PATH. Required for template rendering."
  exit 1
fi

render() {
  local src="$1"
  python3 - "${src}" <<'PY'
import re
import sys

src_path = sys.argv[1]
with open(src_path) as f:
    body = f.read()

# Placeholder values. The schema doesn't care about specific values — only
# that the rendered YAML is structurally valid cloud-config.
vals = {
    "vm_hostname": "lint-host",
    "build_username": "lintuser",
    # Synthetic SHA-512-shaped placeholder — only fed to templatefile()
    # so the rendered YAML is well-formed for cloud-init's schema check.
    # Never reaches a real install, never deployed; the actual hash comes
    # from the BUILD_PASSWORD_ENCRYPTED secret at workflow run time.
    "build_password_encrypted": "$6$rounds=4096$lintsalt$lintHashLintHashLintHashLintHashLintHashLintHashLintHashLintH",
    "locale": "en_GB.UTF-8",
    "keyboard_layout": "gb",
    "timezone": "Europe/London",
    # build_ssh_authorized_keys is HCL-jsonencode()'d at build time — we
    # render the same JSON list inline.
    "build_ssh_authorized_keys": '["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILintLintLintLintLintLintLintLintLintLintL lint@lint"]',
}

# First substitute jsonencode(NAME) → JSON list literal for the known list var.
body = re.sub(
    r"\$\{jsonencode\((\w+)\)\}",
    lambda m: vals.get(m.group(1), '"<unset>"'),
    body,
)

# Then substitute plain ${NAME} → value
def plain(m):
    name = m.group(1)
    if name in vals:
        return vals[name]
    # Any unknown variable at this stage is a real defect — fail loudly with
    # a marker the schema check will spot.
    return f"__UNHANDLED_VAR_{name}__"

body = re.sub(r"\$\{(\w+)\}", plain, body)

# Sanity-check we didn't leave any unhandled ${...} patterns.
remaining = re.findall(r"\$\{[^}]+\}", body)
if remaining:
    print(f"❌ unhandled template patterns in {src_path}:", file=sys.stderr)
    for r in remaining:
        print(f"    {r}", file=sys.stderr)
    sys.exit(2)

sys.stdout.write(body)
PY
}

overall_rc=0

for src in "${TEMPLATES_DIR}"/server-user-data.pkrtpl "${TEMPLATES_DIR}"/desktop-user-data.pkrtpl; do
  [[ -f "${src}" ]] || { echo "⚠️  ${src} not found, skipping"; continue; }
  name=$(basename "${src}")
  echo "==> Rendering + validating ${name}..."

  rendered=$(mktemp --suffix=.yaml)
  trap 'rm -f "${rendered}"' RETURN

  if ! render "${src}" > "${rendered}"; then
    echo "❌ ${name}: render failed"
    overall_rc=1
    rm -f "${rendered}"
    continue
  fi

  # cloud-init schema is the official validator. The user-data is a
  # cloud-config document wrapped under `autoinstall:`, so we use the
  # "autoinstall" schema family. cloud-init's CLI knows it.
  if cloud-init schema --config-file "${rendered}" 2>&1; then
    echo "    ✔ ${name} validates against cloud-init schema"
  else
    echo "    ✘ ${name} failed cloud-init schema validation"
    echo "    Rendered file (first 60 lines):"
    head -60 "${rendered}" | sed 's/^/        /'
    overall_rc=1
  fi
  rm -f "${rendered}"
  trap - RETURN
done

if [[ ${overall_rc} -eq 0 ]]; then
  echo ""
  echo "✅ All user-data templates pass cloud-init schema validation."
fi

exit ${overall_rc}

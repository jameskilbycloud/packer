#!/usr/bin/env bash
# =============================================================================
# check-goss-drift.sh
# Guard against drift between the in-build goss specs and their post-clone
# twins. server.yaml / desktop.yaml and their *-clone.yaml counterparts are
# deliberately maintained as near-duplicates rather than merged via gossfile
# includes (see the header in goss/server-clone.yaml for the rationale). The
# standing instruction is "when you add an assertion to one spec, mirror it in
# the other" — which is easy to forget.
#
# This check compares the SET of assertion keys (not their values — the clone
# specs legitimately invert values like `enabled: true` → `false`) between each
# pair, and fails if they diverge beyond the intentional, allowlisted
# differences below. It catches the classic "added an assertion to one spec but
# forgot to mirror it into the other".
#
# Run by the `goss-drift` pre-commit hook (and thus by pre-commit CI), and
# runnable standalone: bash scripts/check-goss-drift.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import sys, yaml

# A key is "<section>::<assertion>", e.g. "file::/etc/hostname" or
# "service::open-vm-tools".
def keys(path):
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    out = set()
    for section, body in doc.items():
        if isinstance(body, dict):
            out.update(f"{section}::{k}" for k in body)
    return out

# For each (base, clone) pair, the ONLY permitted key-set differences. Anything
# else that diverges is treated as a missed mirror and fails the check.
PAIRS = [
    ("goss/server.yaml", "goss/server-clone.yaml", {
        # The first-boot hostname unit touches this sentinel on the clone's
        # first boot; it can't exist in the pre-convert build spec.
        "clone_only": {"file::/var/lib/packer-firstboot/hostname.done"},
        "base_only":  set(),
    }),
    ("goss/desktop.yaml", "goss/desktop-clone.yaml", {
        # Each desktop spec includes the matching server spec via gossfile.
        "clone_only": {"gossfile::./server-clone.yaml"},
        "base_only":  {"gossfile::./server.yaml"},
    }),
]

failed = False
for base, clone, allow in PAIRS:
    b, c = keys(base), keys(clone)
    clone_only = (c - b) - allow["clone_only"]
    base_only  = (b - c) - allow["base_only"]
    if clone_only or base_only:
        failed = True
        print(f"✘ goss spec drift between {base} and {clone}:")
        for k in sorted(clone_only):
            print(f"    only in {clone}: {k}  (mirror it into {base}?)")
        for k in sorted(base_only):
            print(f"    only in {base}: {k}  (mirror it into {clone}?)")
    else:
        print(f"✔ {base} ↔ {clone}: assertion keys in sync")

sys.exit(1 if failed else 0)
PY

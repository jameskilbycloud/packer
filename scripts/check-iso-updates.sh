#!/usr/bin/env bash
# =============================================================================
# check-iso-updates.sh
# Detects new Ubuntu live-server ISO point releases by comparing the filenames
# hardcoded in this repo against the latest SHA256SUMS published at
# releases.ubuntu.com/<version>/.
#
# Usage:
#   scripts/check-iso-updates.sh           # detect only — prints a summary
#   scripts/check-iso-updates.sh --apply   # detect AND rewrite every reference
#                                          # across the repo to the new filename
#
# When run inside GitHub Actions, writes these outputs to $GITHUB_OUTPUT:
#   drift            — "true" if any version is out of date, else "false"
#   bumped_versions  — space-separated version codes that drifted (e.g. "2204 2604")
#   summary          — markdown table (multi-line) of current vs latest
#
# The "current" filename for each version is read from scripts/upload-isos.sh
# so that map remains the single source of truth; do not duplicate it here.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

# Map version code (used as the upload-isos.sh key) to the URL path component.
declare -A VERSION_PATH=(
  [2204]="22.04"
  [2404]="24.04"
  [2604]="26.04"
)
VERSION_ORDER=(2204 2404 2604)

# Read the current filename from upload-isos.sh's ISO_FILENAME map so we
# don't duplicate it here.
get_current_filename() {
  local version="$1"
  grep -E "^[[:space:]]*\[${version}\]=" scripts/upload-isos.sh | head -1 \
    | grep -oE '"ubuntu-[^"]+\.iso"' | tr -d '"'
}

# Fetch SHA256SUMS for a version and extract the live-server ISO filename.
# The published SHA256SUMS only lists the latest point release, so we don't
# strictly need to sort, but `sort -V | tail -1` is defensive against a file
# that ever lists multiple point releases (e.g. legacy archives).
get_latest_filename() {
  local major_minor="$1"
  local url="https://releases.ubuntu.com/${major_minor}/SHA256SUMS"
  local sums
  if ! sums=$(curl -fsSL --max-time 30 "$url" 2>/dev/null); then
    return 1
  fi
  local mm_escaped="${major_minor//./\\.}"
  echo "$sums" \
    | grep -oE "ubuntu-${mm_escaped}(\\.[0-9]+)?-live-server-amd64\\.iso" \
    | sort -uV | tail -1
}

# Rewrite every occurrence of the old filename across tracked files.
# `git grep -l` scopes to tracked files only — won't touch artifacts, manifests
# build outputs, etc. perl -i is portable between GNU and BSD sed semantics.
apply_bump() {
  local old="$1" new="$2"
  local files
  files=$(git grep -l --fixed-strings -- "$old" || true)
  if [[ -z "$files" ]]; then
    echo "  WARN: no tracked files reference ${old}" >&2
    return 0
  fi
  while IFS= read -r f; do
    perl -i -pe "s|\\Q${old}\\E|${new}|g" "$f"
    echo "  patched: $f"
  done <<< "$files"
}

bumped_versions=()
summary_lines=()
summary_lines+=("| Version | Current | Latest | Status |")
summary_lines+=("| ------- | ------- | ------ | ------ |")

drift=0
for version in "${VERSION_ORDER[@]}"; do
  major_minor="${VERSION_PATH[$version]}"
  current=$(get_current_filename "$version") || current=""
  if [[ -z "$current" ]]; then
    summary_lines+=("| ${version} | _(not in upload-isos.sh map)_ | — | :question: |")
    echo "WARN: no ISO_FILENAME entry for ${version} in scripts/upload-isos.sh" >&2
    continue
  fi
  if ! latest=$(get_latest_filename "$major_minor") || [[ -z "$latest" ]]; then
    summary_lines+=("| ${version} | \`${current}\` | _(lookup failed)_ | :question: |")
    echo "WARN: could not determine latest ISO for ${major_minor}" >&2
    continue
  fi
  if [[ "$current" == "$latest" ]]; then
    summary_lines+=("| ${version} | \`${current}\` | \`${latest}\` | :white_check_mark: up to date |")
  else
    drift=1
    bumped_versions+=("$version")
    summary_lines+=("| ${version} | \`${current}\` | **\`${latest}\`** | :arrow_up: new release |")
    if [[ $APPLY -eq 1 ]]; then
      echo "Bumping ${version}: ${current} -> ${latest}"
      apply_bump "$current" "$latest"
    fi
  fi
done

printf '%s\n' "${summary_lines[@]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    if [[ $drift -eq 1 ]]; then echo "drift=true"; else echo "drift=false"; fi
    echo "bumped_versions=${bumped_versions[*]:-}"
    echo "summary<<__EOF__"
    printf '%s\n' "${summary_lines[@]}"
    echo "__EOF__"
  } >> "$GITHUB_OUTPUT"
fi

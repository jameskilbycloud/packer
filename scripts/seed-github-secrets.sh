#!/usr/bin/env bash
# =============================================================================
# seed-github-secrets.sh
# Bulk-set the pipeline's GitHub Actions secrets and variables from a local
# env file, so you don't have to paste each one into the web UI.
#
#   1. cp .secrets.env.example .secrets.env   # .secrets.env is gitignored
#   2. edit .secrets.env
#   3. bash scripts/seed-github-secrets.sh            # set them
#      bash scripts/seed-github-secrets.sh --dry-run  # preview only
#
# Keys listed in VARIABLE_KEYS below are set as repo *variables* (vars.*);
# every other non-blank key is set as a repo *secret* (secrets.*). Blank values
# are skipped, so re-running only touches keys you've filled in. GITHUB_TOKEN is
# refused — GitHub provides it automatically.
#
# Requires the GitHub CLI (`gh`) authenticated with repo admin rights
# (`gh auth login`). Target repo defaults to the one for the current directory;
# override with --repo <owner/name> or the GH_REPO env var.
# =============================================================================
set -euo pipefail

# Keys that are repo VARIABLES (vars.* in the workflows), not secrets. Keep in
# sync with `grep -rhoE 'vars\.[A-Z_]+' .github/workflows/`.
VARIABLE_KEYS=" CONTENT_LIBRARY RUNNER_LABEL TEMPLATE_RETENTION_COUNT TEMPLATE_PRUNE_DRY_RUN TEMPLATE_CONTENT_LIBRARY QUARANTINE_RETAIN_DAYS PREFLIGHT_MIN_FREE_GB "

ENV_FILE=".secrets.env"
REPO="${GH_REPO:-}"
DRY_RUN=false

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)   ENV_FILE="$2"; shift 2 ;;
    -r|--repo)   REPO="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)   usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "❌ GitHub CLI (gh) not found. Install: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh is not authenticated. Run: gh auth login" >&2; exit 1; }
[[ -f "${ENV_FILE}" ]] || { echo "❌ ${ENV_FILE} not found. Copy .secrets.env.example to .secrets.env and fill it in." >&2; exit 1; }

repo_args=()
[[ -n "${REPO}" ]] && repo_args=(--repo "${REPO}")

secrets_set=0 vars_set=0 skipped=0
target_desc="${REPO:-current repo}"
echo "Seeding GitHub secrets/variables for: ${target_desc}"
${DRY_RUN} && echo "(dry-run — nothing will actually be set)"
echo ""

lineno=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"                       # tolerate CRLF files
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue   # comment line
  [[ "${line}" =~ ^[[:space:]]*$ ]] && continue   # blank line
  [[ "${line}" == *"="* ]] || { echo "  ⚠️  line ${lineno}: no '=', skipping"; continue; }

  key="${line%%=*}"
  value="${line#*=}"
  key="${key//[[:space:]]/}"                 # keys never contain spaces

  if [[ -z "${value}" ]]; then
    skipped=$((skipped + 1)); continue
  fi
  if [[ "${key}" == "GITHUB_TOKEN" ]]; then
    echo "  ⏭️  GITHUB_TOKEN is provided automatically — skipping"
    skipped=$((skipped + 1)); continue
  fi

  if [[ "${VARIABLE_KEYS}" == *" ${key} "* ]]; then
    if ${DRY_RUN}; then
      echo "  variable  ${key}  (would set)"
    else
      printf '%s' "${value}" | gh variable set "${key}" "${repo_args[@]}" --body -
      echo "  variable  ${key}  ✔"
    fi
    vars_set=$((vars_set + 1))
  else
    if ${DRY_RUN}; then
      echo "  secret    ${key}  (would set)"
    else
      # Value via stdin, never on the command line, so it can't leak into `ps`.
      printf '%s' "${value}" | gh secret set "${key}" "${repo_args[@]}"
      echo "  secret    ${key}  ✔"
    fi
    secrets_set=$((secrets_set + 1))
  fi
done < "${ENV_FILE}"

echo ""
if ${DRY_RUN}; then
  echo "Dry-run: would set ${secrets_set} secret(s) + ${vars_set} variable(s); ${skipped} blank/skipped."
else
  echo "Done: ${secrets_set} secret(s) + ${vars_set} variable(s) set; ${skipped} blank/skipped."
fi

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Bulk-set the pipeline's GitHub Actions secrets and variables from a local
  env file — the Windows PowerShell equivalent of seed-github-secrets.sh.

.DESCRIPTION
  For Windows users without Git Bash / WSL. Reads a gitignored .secrets.env and
  sets each non-blank key via the GitHub CLI, routing the repo variables to
  `gh variable set` and everything else to `gh secret set`. Blank values are
  skipped (existing GitHub values untouched), so it's safe to re-run. Keep the
  VariableKeys list in sync with scripts/seed-github-secrets.sh.

  Requires the GitHub CLI (gh) authenticated with repo admin rights:
    winget install GitHub.cli   # or: https://cli.github.com
    gh auth login

.EXAMPLE
  pwsh scripts/seed-github-secrets.ps1
  pwsh scripts/seed-github-secrets.ps1 -DryRun
  pwsh scripts/seed-github-secrets.ps1 -File .secrets.env -Repo owner/name
#>
[CmdletBinding()]
param(
  [string]$File = ".secrets.env",
  [string]$Repo = $env:GH_REPO,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Keys that are repo VARIABLES (vars.* in the workflows), not secrets. Keep in
# sync with VARIABLE_KEYS in scripts/seed-github-secrets.sh.
$VariableKeys = @(
  "CONTENT_LIBRARY", "RUNNER_LABEL", "TEMPLATE_RETENTION_COUNT",
  "TEMPLATE_PRUNE_DRY_RUN", "TEMPLATE_CONTENT_LIBRARY",
  "QUARANTINE_RETAIN_DAYS", "PREFLIGHT_MIN_FREE_GB"
)

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error "GitHub CLI (gh) not found. Install: winget install GitHub.cli  (or https://cli.github.com)"
  exit 1
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Write-Error "gh is not authenticated. Run: gh auth login"; exit 1 }
if (-not (Test-Path -LiteralPath $File)) {
  Write-Error "$File not found. Copy .secrets.env.example to .secrets.env and fill it in."
  exit 1
}

$repoArgs = @()
if ($Repo) { $repoArgs = @("--repo", $Repo) }

$secretsSet = 0; $varsSet = 0; $skipped = 0
$target = if ($Repo) { $Repo } else { "current repo" }
Write-Host "Seeding GitHub secrets/variables for: $target"
if ($DryRun) { Write-Host "(dry-run - nothing will actually be set)" }
Write-Host ""

$lineno = 0
foreach ($raw in Get-Content -LiteralPath $File) {
  $lineno++
  $line = $raw.TrimEnd("`r", "`n")          # tolerate CRLF (Notepad default)
  if ($line -match '^\s*#') { continue }     # comment line
  if ($line -match '^\s*$') { continue }     # blank line
  if ($line -notmatch '=') { Write-Host "  line ${lineno}: no '=', skipping"; continue }

  $idx = $line.IndexOf('=')
  $key = $line.Substring(0, $idx).Trim()
  $value = $line.Substring($idx + 1)

  if ([string]::IsNullOrEmpty($value)) { $skipped++; continue }
  if ($key -eq "GITHUB_TOKEN") {
    Write-Host "  GITHUB_TOKEN is provided automatically - skipping"; $skipped++; continue
  }

  # --body passes the value verbatim (no trailing newline, unlike piping a
  # PowerShell string to stdin). On your own machine the brief command-line
  # exposure is acceptable; the bash version uses stdin for the shared-runner case.
  if ($VariableKeys -contains $key) {
    if ($DryRun) { Write-Host "  variable  $key  (would set)" }
    else { gh variable set $key @repoArgs --body $value; Write-Host "  variable  $key  set" }
    $varsSet++
  }
  else {
    if ($DryRun) { Write-Host "  secret    $key  (would set)" }
    else { gh secret set $key @repoArgs --body $value; Write-Host "  secret    $key  set" }
    $secretsSet++
  }
}

Write-Host ""
if ($DryRun) {
  Write-Host "Dry-run: would set $secretsSet secret(s) + $varsSet variable(s); $skipped blank/skipped."
}
else {
  Write-Host "Done: $secretsSet secret(s) + $varsSet variable(s) set; $skipped blank/skipped."
}

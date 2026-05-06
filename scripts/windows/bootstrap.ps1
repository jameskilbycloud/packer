# =============================================================================
# bootstrap.ps1 — Enable WinRM for Packer
# =============================================================================
# Runs once at first logon (triggered by FirstLogonCommands in autounattend).
# Output is captured to C:\Windows\Temp\bootstrap.{log,err} by the wrapper.
#
# This script must be self-contained — it has no network and no provisioner
# infrastructure yet. Its only job is to bring WinRM up so Packer can connect.
# All "real" provisioning happens in subsequent .ps1 scripts run via Packer's
# powershell provisioner once WinRM is reachable.
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Write-Output "[$(Get-Date -Format o)] bootstrap.ps1 starting"

# ── Enable PSRemoting (idempotent on a fresh install) ────────────────────────
# -Force suppresses prompts; -SkipNetworkProfileCheck allows it on Public networks
# (the build network often profiles as Public until joined to a domain).
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# ── Configure WinRM HTTP listener for Packer ─────────────────────────────────
# Packer connects with `winrm_use_ssl = false` over port 5985. We allow basic
# auth and unencrypted traffic ONLY for the build — sysprep + post-deploy GPO
# should re-tighten this on cloned VMs.
winrm quickconfig -q
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="100"}'

# ── Firewall ─────────────────────────────────────────────────────────────────
# Open 5985 in case the WinRM listener didn't add the rule (it usually does).
$ruleName = 'WinRM-HTTP-In-Packer'
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName 'WinRM HTTP (Packer build)' `
        -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound `
        -Profile Any
}

# ── Start service ────────────────────────────────────────────────────────────
Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM

Write-Output "[$(Get-Date -Format o)] bootstrap.ps1 complete — WinRM listening on 5985"

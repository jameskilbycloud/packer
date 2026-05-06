# =============================================================================
# install-vmtools.ps1 — Install VMware Tools
# =============================================================================
# Packer's vsphere-iso builder mounts the VMware Tools ISO automatically when
# `tools_upload_flavor = "windows"` is set, exposing it as a CD-ROM. We locate
# setup64.exe on whichever drive that landed on and run a silent install.
#
# A reboot is required after install; Packer reboots between provisioners
# only when explicitly asked, so we set $env:PACKER_BUILDER_TYPE-aware
# behaviour: just shut down — the next provisioner step is run via a fresh
# WinRM session after the windows-restart provisioner.
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Write-Output "==> Locating VMware Tools setup64.exe..."

$setup = $null
foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match '^[A-Z]$' })) {
    $candidate = Join-Path $drive.Root 'setup64.exe'
    if (Test-Path $candidate) {
        # Confirm it's the VMware Tools installer, not some random setup64.exe
        $info = (Get-Item $candidate).VersionInfo
        if ($info.FileDescription -match 'VMware Tools' -or $info.ProductName -match 'VMware Tools') {
            $setup = $candidate
            break
        }
    }
}

if (-not $setup) {
    Write-Output "==> setup64.exe not found on any mounted drive."
    Write-Output "==> Mounted drives:"
    Get-PSDrive -PSProvider FileSystem | Format-Table -AutoSize | Out-String | Write-Output
    throw "VMware Tools ISO is not mounted. In the Packer source, set tools_upload_flavor = 'windows'."
}

Write-Output "==> Found: $setup"
Write-Output "==> Running silent install..."

# /S /v"/qn REBOOT=R" — silent, no reboot. ADDLOCAL=ALL installs everything.
# Exit code 3010 means "success, reboot required" — treat that as success here
# and let the windows-restart provisioner handle the reboot.
$proc = Start-Process -FilePath $setup `
    -ArgumentList '/S','/v','/qn REBOOT=R ADDLOCAL=ALL' `
    -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "VMware Tools installer exited with code $($proc.ExitCode)"
}

Write-Output "==> VMware Tools install complete (exit code $($proc.ExitCode)). Reboot pending."

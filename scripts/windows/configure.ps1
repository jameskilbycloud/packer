# =============================================================================
# configure.ps1 — Common post-install hardening for Windows templates
# =============================================================================
# Runs via Packer's powershell provisioner once WinRM is reachable. Equivalent
# of setup.sh on the Linux side: clean up build artefacts, disable noisy
# defaults, prepare the image for sysprep.
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Write-Output "==> Disabling Windows hibernation (saves ~RAM-sized hiberfil.sys)..."
powercfg /hibernate off

Write-Output "==> Setting power plan to High performance..."
# Some SKUs don't expose High Performance — fall through silently.
$plan = powercfg /list 2>$null | Select-String 'High performance'
if ($plan) {
    $guid = ($plan -split '\s+')[3]
    powercfg /setactive $guid
}

Write-Output "==> Disabling unused services for a leaner template..."
$servicesToDisable = @(
    'DiagTrack',          # Connected User Experiences and Telemetry
    'dmwappushservice',   # WAP Push Message Routing (telemetry)
    'WerSvc'              # Windows Error Reporting
)
foreach ($svc in $servicesToDisable) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Write-Output "    disabling $svc"
        Set-Service -Name $svc -StartupType Disabled
        if ($s.Status -eq 'Running') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output "==> Disabling scheduled telemetry tasks..."
$tasksToDisable = @(
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
)
foreach ($t in $tasksToDisable) {
    schtasks /Change /TN $t /Disable 2>$null | Out-Null
}

Write-Output "==> Clearing Windows Update download cache..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue
Start-Service -Name wuauserv -ErrorAction SilentlyContinue

Write-Output "==> Cleaning up temp files..."
Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:USERPROFILE\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "==> configure.ps1 complete."

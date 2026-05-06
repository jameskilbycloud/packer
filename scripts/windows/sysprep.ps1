# =============================================================================
# sysprep.ps1 — Generalize the image and shut down
# =============================================================================
# Final provisioner step. Runs sysprep with /generalize + /oobe + /shutdown,
# which strips the machine SID, removes per-machine identifiers, and powers
# the VM off. Packer then converts the powered-off VM into a template.
#
# IMPORTANT: this must be the LAST provisioner — anything after sysprep will
# be undone or run on a generalized image where it doesn't belong.
#
# We pass a dummy unattend.xml that re-enables OOBE skip on the cloned VM's
# first boot, so deployments from the template come up logged in as a fresh
# Administrator without an interactive OOBE.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Drop a generalize-pass unattend that suppresses the OOBE on cloned VMs.
$unattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="generalize">
    <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SkipRearm>1</SkipRearm>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
'@

$unattendPath = 'C:\Windows\Temp\sysprep-unattend.xml'
Set-Content -Path $unattendPath -Value $unattend -Encoding UTF8

Write-Output "==> Running sysprep (generalize + OOBE + shutdown)..."
$sysprep = "$env:windir\System32\Sysprep\sysprep.exe"
& $sysprep /generalize /oobe /shutdown /quiet /unattend:$unattendPath

# Sysprep returns immediately and shuts down asynchronously. Packer's
# shutdown_command in the source uses this script's exit, then the
# `shutdown_timeout` covers the remaining shutdown.
Write-Output "==> Sysprep invoked. VM will shut down momentarily."

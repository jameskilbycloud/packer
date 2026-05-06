# =============================================================================
# Windows Server 2022 (Long-Term Servicing Channel)
# =============================================================================
# Build the Standard with Desktop Experience edition by default. To build
# Datacenter or Server Core, override windows_server_2022_image_name and
# update the product key local below to match the edition.
#
# Run:
#   packer build -var-file=variables.pkrvars.hcl -only='windows-server-2022.*' .
# =============================================================================

locals {
  # Generic KMS Client Setup Key — does NOT activate Windows; it only suppresses
  # the "enter product key" install prompt. The OS remains unactivated post-build
  # (180-day grace period if the ISO is the Eval edition; otherwise unlicensed).
  # See: https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
  #
  # Standard:   VDYBN-27WPP-V4HQT-9VMD4-VMK7H
  # Datacenter: WX4NM-KYWYW-QJJR4-XV3QB-6VM33
  windows_server_2022_product_key = "VDYBN-27WPP-V4HQT-9VMD4-VMK7H"
}

source "vsphere-iso" "windows-server-2022" {

  # vSphere connection
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  # Placement
  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  # VM identity
  vm_name       = "windows-server-2022-${local.build_date}"
  guest_os_type = "windows2019srv_64Guest" # vSphere lacks an explicit 2022 type; 2019 is forward-compatible
  notes         = "Windows Server 2022 — built by Packer on ${local.build_timestamp}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM
  CPUs            = 1
  cpu_cores       = var.windows_server_cpu_count
  RAM             = var.windows_server_ram_mb
  RAM_reserve_all = false

  # Firmware — EFI without Secure Boot. Server 2022 supports Secure Boot but
  # we keep parity with the Ubuntu sources and avoid the cert-store complexity.
  firmware = "efi"

  # Storage
  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.windows_server_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  # Network
  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  # ISO paths — primary is the Windows installer, secondary is the ESXi-bundled
  # VMware Tools ISO so install-vmtools.ps1 can find setup64.exe on a CD-ROM.
  # The empty-datastore syntax `[]` resolves to the ESXi host's local /vmimages.
  iso_paths = [
    "[${var.vsphere_iso_datastore}] ${var.windows_server_2022_iso_path}",
    "[] /vmimages/tools-isoimages/windows.iso",
  ]

  # Cloud-init equivalent: a secondary CD labelled "cidata" carrying
  # Autounattend.xml (auto-detected by Windows Setup) and bootstrap.ps1
  # (run by FirstLogonCommands inside the autounattend).
  cd_content = {
    "Autounattend.xml" = templatefile("${path.root}/templates/windows-server-autounattend.pkrtpl", {
      image_name     = var.windows_server_2022_image_name
      product_key    = local.windows_server_2022_product_key
      admin_password = var.windows_admin_password
      computer_name  = "winsrv2022"
      timezone       = var.windows_timezone
    })
  }
  cd_files = ["${path.root}/scripts/windows/bootstrap.ps1"]
  cd_label = "cidata"

  # No boot_command — Windows Setup auto-loads from the primary CD on UEFI
  # boot and discovers Autounattend.xml on the secondary CD without user
  # interaction. boot_wait gives the firmware time to enumerate both ISOs.
  boot_order = "disk,cdrom"
  boot_wait  = "2s"

  # Wait for the installer to provision the disk, reboot, run OOBE,
  # autoLogon as Administrator, and run bootstrap.ps1 — typically 15-25 min.
  ip_wait_timeout   = "60m"
  ip_settle_timeout = "5m"

  # WinRM communicator (HTTP, port 5985)
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.windows_admin_password
  winrm_port     = 5985
  winrm_use_ssl  = false
  winrm_insecure = true
  winrm_timeout  = local.windows_winrm_timeout

  # Sysprep handles shutdown — Packer just needs to wait for power off.
  shutdown_command = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\\Windows\\Temp\\packer-sysprep.ps1"
  shutdown_timeout = local.windows_shutdown_timeout

  # Output
  convert_to_template = true
}

build {
  name    = "windows-server-2022"
  sources = ["source.vsphere-iso.windows-server-2022"]

  # Stage sysprep.ps1 onto the VM so the shutdown_command can invoke it.
  # We drop it into Temp rather than running it inline — sysprep takes a few
  # seconds to spin up and we don't want WinRM holding the session open.
  provisioner "file" {
    source      = "${path.root}/scripts/windows/sysprep.ps1"
    destination = "C:/Windows/Temp/packer-sysprep.ps1"
  }

  # Install VMware Tools first — its installer reboots the VM, after which
  # WinRM reconnects and the rest of the provisioners run.
  provisioner "powershell" {
    script = "${path.root}/scripts/windows/install-vmtools.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # Common cleanup / hardening.
  provisioner "powershell" {
    script = "${path.root}/scripts/windows/configure.ps1"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/windows-server-2022.json"
    strip_path = true
  }
}

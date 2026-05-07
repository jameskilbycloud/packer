# =============================================================================
# Windows Server 2025 (Long-Term Servicing Channel)
# =============================================================================
# Build the Standard with Desktop Experience edition by default. To build
# Datacenter or Server Core, override windows_server_2025_image_name and
# update the product key local below to match the edition.
#
# Run:
#   packer build -var-file=variables.pkrvars.hcl -only='windows-server-2025.*' .
# =============================================================================

locals {
  # Generic KMS Client Setup Key for Server 2025 — does NOT activate Windows;
  # only suppresses the "enter product key" install prompt. The OS remains
  # unactivated post-build.
  # See: https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
  #
  # Standard:   TVRH6-WHNXV-R9WG3-9XRFY-MY832
  # Datacenter: D764K-2NDRG-47T6Q-P8T8W-YP6DF
  windows_server_2025_product_key = "TVRH6-WHNXV-R9WG3-9XRFY-MY832"
}

source "vsphere-iso" "windows-server-2025" {

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
  vm_name       = "windows-server-2025-${local.build_date}"
  guest_os_type = "windows2019srv_64Guest" # vSphere lacks an explicit 2025 type until 8.0 U3+; 2019 is forward-compatible
  notes         = "Windows Server 2025 — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM
  CPUs            = 1
  cpu_cores       = var.windows_server_cpu_count
  RAM             = var.windows_server_ram_mb
  RAM_reserve_all = false

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
  iso_paths = [
    "[${var.vsphere_iso_datastore}] ${var.windows_server_2025_iso_path}",
    "[] /vmimages/tools-isoimages/windows.iso",
  ]

  # Autounattend + bootstrap on a secondary CD
  cd_content = {
    "Autounattend.xml" = templatefile("${path.root}/templates/windows-server-autounattend.pkrtpl", {
      image_name     = var.windows_server_2025_image_name
      product_key    = local.windows_server_2025_product_key
      admin_password = var.windows_admin_password
      computer_name  = "winsrv2025"
      timezone       = var.windows_timezone
    })
  }
  cd_files = ["${path.root}/scripts/windows/bootstrap.ps1"]
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "2s"

  ip_wait_timeout   = "60m"
  ip_settle_timeout = "5m"

  # WinRM
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.windows_admin_password
  winrm_port     = 5985
  winrm_use_ssl  = false
  winrm_insecure = true
  winrm_timeout  = local.windows_winrm_timeout

  shutdown_command = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\\Windows\\Temp\\packer-sysprep.ps1"
  shutdown_timeout = local.windows_shutdown_timeout

  convert_to_template = true
}

build {
  name    = "windows-server-2025"
  sources = ["source.vsphere-iso.windows-server-2025"]

  provisioner "file" {
    source      = "${path.root}/scripts/windows/sysprep.ps1"
    destination = "C:/Windows/Temp/packer-sysprep.ps1"
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/windows/install-vmtools.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/windows/configure.ps1"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/windows-server-2025.json"
    strip_path = true
  }
}

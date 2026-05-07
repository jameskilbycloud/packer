# =============================================================================
# Windows 10
# =============================================================================
# Build Windows 10 Enterprise (the SKU shipped on the Microsoft Evaluation
# Center ISO) by default. To build Pro or another edition, override
# windows_10_image_name and the product key local below.
#
# Run:
#   packer build -var-file=variables.pkrvars.hcl -only='windows-10.*' .
# =============================================================================

locals {
  # Generic KMS Client Setup Key for Windows 10 — does NOT activate Windows;
  # only suppresses the install prompt. Eval ISO grants 90 days; otherwise
  # the OS is unlicensed post-build.
  # See: https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
  #
  # Enterprise: NPPR9-FWDCX-D2C8J-H872K-2YT43
  # Pro:        W269N-WFGWX-YVC9B-4J6C9-T83GX
  windows_10_product_key = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
}

source "vsphere-iso" "windows-10" {

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
  vm_name       = "windows-10-${local.build_date}"
  guest_os_type = "windows9_64Guest" # vSphere's identifier for Windows 10 / 11
  notes         = "Windows 10 — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM
  CPUs            = 1
  cpu_cores       = var.windows_desktop_cpu_count
  RAM             = var.windows_desktop_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  # Storage
  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.windows_desktop_disk_gb * 1024
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
    "[${var.vsphere_iso_datastore}] ${var.windows_10_iso_path}",
    "[] /vmimages/tools-isoimages/windows.iso",
  ]

  # Autounattend + bootstrap on a secondary CD
  cd_content = {
    "Autounattend.xml" = templatefile("${path.root}/templates/windows-10-autounattend.pkrtpl", {
      image_name     = var.windows_10_image_name
      product_key    = local.windows_10_product_key
      admin_password = var.windows_admin_password
      computer_name  = "win10"
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
  name    = "windows-10"
  sources = ["source.vsphere-iso.windows-10"]

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
    output     = "${path.root}/manifests/windows-10.json"
    strip_path = true
  }
}

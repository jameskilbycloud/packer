# =============================================================================
# Ubuntu 26.04 LTS (Plucky Puffin) — Server & Desktop
# =============================================================================
# NOTE: Ubuntu 26.04 was released in April 2026. Update ubuntu_2604_iso_path
# in your .pkrvars.hcl once you have downloaded the final ISO.
#
# Run a single build (glob required — build label prefix varies):
#   packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2604-server' .
#   packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2604-desktop' .
# =============================================================================

# ── Ubuntu 26.04 Server ───────────────────────────────────────────────────────

source "vsphere-iso" "ubuntu-2604-server" {

  # vSphere connection
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  # Placement
  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster
  host       = var.vsphere_host
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  # VM identity
  vm_name       = "ubuntu-2604-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 26.04 LTS Server — built by Packer on ${local.build_timestamp}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM
  CPUs            = 1
  cpu_cores       = var.server_cpu_count
  RAM             = var.server_ram_mb
  RAM_reserve_all = false

  # Firmware — EFI without Secure Boot. Secure Boot locks GRUB's edit/command
  # keys (e/c) which Packer needs to inject autoinstall kernel parameters.
  firmware = "efi"

  # Storage
  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.server_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  # Network
  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  # ISO
  iso_paths = ["[${var.vsphere_iso_datastore}] ${var.ubuntu_2604_iso_path}"]

  # Cloud-init / autoinstall seed
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname              = "ubuntu-2604-server"
      build_username           = var.build_username
      build_password_encrypted = var.build_password_encrypted
    })
  }
  cd_label = "cidata"

  # Boot — press 'e' to edit the highlighted GRUB entry, navigate to the
  # kernel line, append autoinstall params, then F10 to boot. This is more
  # reliable on EFI than the <esc>c command-line approach.
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "<wait5>",
    "e<wait2>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud",
    "<f10><wait30>"
  ]

  # SSH communicator
  communicator = "ssh"
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = local.ssh_timeout
  ssh_port     = 22

  # Shutdown
  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  # Output
  convert_to_template = true
}

# ── Ubuntu 26.04 Desktop ──────────────────────────────────────────────────────

source "vsphere-iso" "ubuntu-2604-desktop" {

  # vSphere connection
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  # Placement
  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster
  host       = var.vsphere_host
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  # VM identity
  vm_name       = "ubuntu-2604-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 26.04 LTS Desktop — built by Packer on ${local.build_timestamp}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM
  CPUs            = 1
  cpu_cores       = var.desktop_cpu_count
  RAM             = var.desktop_ram_mb
  RAM_reserve_all = false

  # Firmware — EFI without Secure Boot. Secure Boot locks GRUB's edit/command
  # keys (e/c) which Packer needs to inject autoinstall kernel parameters.
  firmware = "efi"

  # Storage
  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.desktop_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  # Network
  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  # ISO
  iso_paths = ["[${var.vsphere_iso_datastore}] ${var.ubuntu_2604_iso_path}"]

  # Cloud-init / autoinstall seed
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname              = "ubuntu-2604-desktop"
      build_username           = var.build_username
      build_password_encrypted = var.build_password_encrypted
    })
  }
  cd_label = "cidata"

  # Boot — press 'e' to edit the highlighted GRUB entry, navigate to the
  # kernel line, append autoinstall params, then F10 to boot. This is more
  # reliable on EFI than the <esc>c command-line approach.
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "<wait5>",
    "e<wait2>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud",
    "<f10><wait30>"
  ]

  # SSH communicator
  communicator = "ssh"
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = local.desktop_ssh_timeout
  ssh_port     = 22

  # Shutdown
  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  # Output
  convert_to_template = true
}

# ── Builds ────────────────────────────────────────────────────────────────────

build {
  name    = "ubuntu-2604-server"
  sources = ["source.vsphere-iso.ubuntu-2604-server"]

  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts = [
      "${path.root}/scripts/setup.sh",
      "${path.root}/scripts/vmtools.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2604-server.json"
    strip_path = true
  }
}

build {
  name    = "ubuntu-2604-desktop"
  sources = ["source.vsphere-iso.ubuntu-2604-desktop"]

  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts = [
      "${path.root}/scripts/setup.sh",
      "${path.root}/scripts/vmtools.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2604-desktop.json"
    strip_path = true
  }
}

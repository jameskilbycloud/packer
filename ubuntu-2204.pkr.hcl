# =============================================================================
# Ubuntu 22.04 LTS (Jammy Jellyfish) — Server & Desktop
# =============================================================================
# Run a single build (glob required — build label prefix varies):
#   packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2204-server' .
#   packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2204-desktop' .
# =============================================================================

# ── Ubuntu 22.04 Server ───────────────────────────────────────────────────────

source "vsphere-iso" "ubuntu-2204-server" {

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
  vm_name       = "ubuntu-2204-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 22.04 LTS Server — built by Packer on ${local.build_timestamp}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM
  CPUs            = 1
  cpu_cores       = var.server_cpu_count
  RAM             = var.server_ram_mb
  RAM_reserve_all = false

  # Firmware — EFI without Secure Boot. Secure Boot locks GRUB's edit/command
  # keys (e/c) which Packer needs to inject autoinstall kernel parameters.
  # The finished template can be redeployed with Secure Boot enabled.
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

  # ISO — points to the Ubuntu 22.04 live-server ISO on the datastore
  iso_paths = ["[${var.vsphere_iso_datastore}] ${var.ubuntu_2204_iso_path}"]

  # Cloud-init / autoinstall seed — mounted as a CD-ROM labelled "cidata"
  # Packer renders the template at build time, injecting credentials from variables.
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname              = "ubuntu-2204-server"
      build_username           = var.build_username
      build_password_encrypted = var.build_password_encrypted
    })
  }
  cd_label = "cidata"

  # Boot — type 'c' during the GRUB countdown to open the command line, then
  # specify the kernel and initrd explicitly. This is version-agnostic and
  # avoids the entry editor (e) whose line count varies by ISO. Do NOT use
  # <esc> before 'c' — on EFI GRUB, Escape exits the bootloader entirely.
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  # IP settle timeout — Ubuntu's live installer starts with a DUID-based DHCP
  # lease, then autoinstall applies the netplan config (dhcp-identifier: mac)
  # which triggers a new DHCP negotiation and a different IP. The default 5s
  # settle time causes Packer to lock onto the first (installer) address before
  # the transition; 5m gives the lease time to stabilise on the MAC-based IP
  # that the installed OS will also use.
  ip_settle_timeout = "5m"

  # SSH communicator (Packer connects once cloud-init completes the install)
  communicator = "ssh"
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = local.ssh_timeout
  ssh_port     = 22

  # Shutdown
  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  # Output — convert the finished VM to a vSphere template
  convert_to_template = true
}

# ── Ubuntu 22.04 Desktop ──────────────────────────────────────────────────────

source "vsphere-iso" "ubuntu-2204-desktop" {

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
  vm_name       = "ubuntu-2204-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 22.04 LTS Desktop — built by Packer on ${local.build_timestamp}"
  vm_version    = var.vm_hardware_version

  # CPU / RAM (desktop needs more resources for the GUI)
  CPUs            = 1
  cpu_cores       = var.desktop_cpu_count
  RAM             = var.desktop_ram_mb
  RAM_reserve_all = false

  # Firmware
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

  # ISO — same live-server ISO; ubuntu-desktop packages are installed via autoinstall
  iso_paths = ["[${var.vsphere_iso_datastore}] ${var.ubuntu_2204_iso_path}"]

  # Cloud-init / autoinstall seed
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname              = "ubuntu-2204-desktop"
      build_username           = var.build_username
      build_password_encrypted = var.build_password_encrypted
    })
  }
  cd_label = "cidata"

  # Boot
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  # IP settle timeout — see server source comment above for full explanation.
  ip_settle_timeout = "5m"

  # SSH communicator
  communicator = "ssh"
  ssh_username = var.build_username
  ssh_password = var.build_password
  # Desktop installs take longer due to ubuntu-desktop package set
  ssh_timeout = local.desktop_ssh_timeout
  ssh_port    = 22

  # Shutdown
  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  # Output
  convert_to_template = true
}

# ── Builds ────────────────────────────────────────────────────────────────────

build {
  name    = "ubuntu-2204-server"
  sources = ["source.vsphere-iso.ubuntu-2204-server"]

  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts = [
      "${path.root}/scripts/setup.sh",
      "${path.root}/scripts/vmtools.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2204-server.json"
    strip_path = true
  }
}

build {
  name    = "ubuntu-2204-desktop"
  sources = ["source.vsphere-iso.ubuntu-2204-desktop"]

  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts = [
      "${path.root}/scripts/setup.sh",
      "${path.root}/scripts/vmtools.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2204-desktop.json"
    strip_path = true
  }
}

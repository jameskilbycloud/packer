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
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
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

  # IP settle timeout — must be longer than the OS install time. The live
  # installer holds a stable IP throughout the install (~8-15 min for server),
  # so a short settle time fires on the installer's IP. After the VM reboots,
  # the installed OS gets a NEW IP (different DUID from regenerated machine-id),
  # the settle timer resets, and only fires once that new IP is stable for the
  # full duration. Packer then targets the correct post-install IP for SSH.
  ip_settle_timeout = "20m"

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
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
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

  # The Ubuntu live installer ISO includes open-vm-tools, so VMware Tools
  # reports an IP within ~40s of boot (the live installer's IP, not the
  # installed OS). ip_settle_timeout is therefore kept short — Packer starts
  # SSH retries early, hits connection refused while the installer runs
  # (early-commands stopped SSH), then connects once the installed OS boots
  # on the same IP (~65-76 min into the build).
  # desktop_ssh_timeout = "120m" covers the full install + reboot window.
  # ip_wait_timeout must remain > ip_settle_timeout.
  ip_wait_timeout   = "120m"
  ip_settle_timeout = "10m"

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
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
    ]
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
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  # desktop.sh installs ubuntu-desktop-minimal which upgrades systemd.
  # The systemd postinst runs daemon-reexec, killing the SSH session (exit 2300218).
  # expect_disconnect=true tells Packer the disconnect is intentional so it
  # reconnects cleanly for the vmtools step rather than treating it as a failure.
  # valid_exit_codes kept as belt-and-suspenders for versions that honour it.
  provisioner "shell" {
    execute_command   = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2204-desktop.json"
    strip_path = true
  }
}

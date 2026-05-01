# =============================================================================
# Ubuntu 24.04 LTS (Noble Numbat) — Server & Desktop
# =============================================================================
# Run a single build (glob required — build label prefix varies):
#   packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2404-server' .
#   packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2404-desktop' .
# =============================================================================

# ── Ubuntu 24.04 Server ───────────────────────────────────────────────────────

source "vsphere-iso" "ubuntu-2404-server" {

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
  vm_name       = "ubuntu-2404-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 24.04 LTS Server — built by Packer on ${local.build_timestamp}"
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
  iso_paths = ["[${var.vsphere_iso_datastore}] ${var.ubuntu_2404_iso_path}"]

  # Cloud-init / autoinstall seed
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname              = "ubuntu-2404-server"
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

# ── Ubuntu 24.04 Desktop ──────────────────────────────────────────────────────

source "vsphere-iso" "ubuntu-2404-desktop" {

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
  vm_name       = "ubuntu-2404-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 24.04 LTS Desktop — built by Packer on ${local.build_timestamp}"
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
  iso_paths = ["[${var.vsphere_iso_datastore}] ${var.ubuntu_2404_iso_path}"]

  # Cloud-init / autoinstall seed
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname              = "ubuntu-2404-desktop"
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

  # ip_wait_timeout and ip_settle_timeout run CONCURRENTLY from when the VM
  # first reports any IP via VMware Tools (typically ~3 min after boot).
  #
  # ip_settle_timeout is the intended gate: Packer waits this long before
  # attempting SSH, ensuring the live installer has finished and rebooted into
  # the installed OS. It MUST be longer than the actual install time, otherwise
  # Packer tries SSH against the live installer where early-commands stopped SSH
  # (connection refused → ssh_timeout exhausted → "SSH timeout").
  #
  # ip_wait_timeout must be GREATER than ip_settle_timeout — they run
  # concurrently and if ip_wait fires first you get "timeout waiting for IP".
  #
  # Desktop install time in this environment: ~50-65 min (ubuntu-desktop-minimal
  # pulls significant packages from the internet). 75m settle gives ~10-25 min
  # of margin. ip_wait at 120m ensures it never fires before settle completes.
  ip_wait_timeout   = "120m"
  ip_settle_timeout = "75m"

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
  name    = "ubuntu-2404-server"
  sources = ["source.vsphere-iso.ubuntu-2404-server"]

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
    output     = "${path.root}/manifests/ubuntu-2404-server.json"
    strip_path = true
  }
}

build {
  name    = "ubuntu-2404-desktop"
  sources = ["source.vsphere-iso.ubuntu-2404-desktop"]

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
    output     = "${path.root}/manifests/ubuntu-2404-desktop.json"
    strip_path = true
  }
}

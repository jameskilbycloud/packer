# =============================================================================
# Ubuntu 26.04 LTS (Plucky Puffin) — Server & Desktop
# =============================================================================
# NOTE: Ubuntu 26.04 was released in April 2026. Update ubuntu_2604_iso_path
# in your .pkrvars.hcl once you have downloaded the final ISO.
#
# Server + desktop are defined as two sources inside a single `build {}` block,
# which lets Packer run them in parallel from one runner. Cap concurrency with
# `-parallel-builds=N` so vSphere isn't overwhelmed.
#
# Run server + desktop in parallel (one Packer process):
#   packer build -var-file=variables.pkrvars.hcl -parallel-builds=2 -only='ubuntu-2604.*' .
#
# Run a single source:
#   packer build -var-file=variables.pkrvars.hcl -only='ubuntu-2604.vsphere-iso.ubuntu-2604-server'  .
#   packer build -var-file=variables.pkrvars.hcl -only='ubuntu-2604.vsphere-iso.ubuntu-2604-desktop' .
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
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  # VM identity
  vm_name       = "ubuntu-2604-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 26.04 LTS Server — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
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
      timezone                 = var.timezone
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

  # IP settle timeout — kept short so it fires during the live install phase,
  # not after the reboot. Packer starts SSH retries early (hitting ECONNREFUSED
  # while early-commands hold port 22 closed), then connects once the installed
  # OS boots. This works because late-commands copies /run/machine-id into the
  # installed OS, giving it the same DUID as the live installer → same DHCP
  # lease → same IP after reboot → Packer's retries succeed.
  # Ubuntu 26.04's install takes longer than 22.04/24.04 (~30-50 min vs ~10 min)
  # so a 20m settle timeout would fire post-install on 22.04/24.04 but mid-install
  # on 26.04. 5m fires consistently during the live phase on all versions.
  ip_settle_timeout = "5m"

  # SSH communicator — 120m covers the full install + reboot + SSH-up window
  # (ip_settle_timeout fires at ~5 min; installed OS SSH is up ~35-55 min later).
  communicator = "ssh"
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = "120m"
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
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  # VM identity
  vm_name       = "ubuntu-2604-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu 26.04 LTS Desktop — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
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
      timezone                 = var.timezone
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

  # The Ubuntu live installer ISO includes open-vm-tools, so VMware Tools
  # reports an IP within ~40s of boot (the live installer's IP, not the
  # installed OS). ip_settle_timeout is therefore kept short — Packer starts
  # SSH retries early, hits connection refused while the installer runs
  # (early-commands stopped SSH), then connects once the installed OS boots
  # on the same IP. Ubuntu 26.04 desktop builds take longer than 24.04 due to
  # the larger package set and snap-related first boot work, so extend the
  # wait window for the post-install SSH phase.
  # ip_wait_timeout must remain > ip_settle_timeout.
  ip_wait_timeout   = "150m"
  ip_settle_timeout = "10m"

  # SSH communicator
  communicator = "ssh"
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = local.desktop_2604_ssh_timeout
  ssh_port     = 22

  # Shutdown
  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  # Output
  convert_to_template = true
}

# ── Build ─────────────────────────────────────────────────────────────────────
# Single build with both sources. Packer runs them in parallel when invoked
# with `-parallel-builds=N` (N>=2). Provisioners that only apply to one source
# are scoped with `only = [...]`. Provisioners without `only` apply to every
# source in the build.

build {
  name = "ubuntu-2604"
  sources = [
    "source.vsphere-iso.ubuntu-2604-server",
    "source.vsphere-iso.ubuntu-2604-desktop",
  ]

  # Server: setup.sh + vmtools.sh in one provisioner step.
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-server"]
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

  # Desktop: setup.sh first.
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  # Desktop: desktop.sh installs ubuntu-desktop-minimal which upgrades systemd.
  # The systemd postinst runs daemon-reexec, killing the SSH session (exit 2300218).
  # expect_disconnect=true tells Packer the disconnect is intentional so it
  # reconnects cleanly for the vmtools step rather than treating it as a failure.
  # valid_exit_codes kept as belt-and-suspenders for versions that honour it.
  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  # Desktop: vmtools.sh after the desktop install completes.
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  # One manifest covers both sources (entries appear in builds[]).
  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2604.json"
    strip_path = true
  }
}

# =============================================================================
# Ubuntu 24.04 LTS (Noble Numbat) — Server & Desktop
# =============================================================================
# Server + desktop are defined as two sources inside a single `build {}` block,
# which lets Packer run them in parallel from one runner. Cap concurrency with
# `-parallel-builds=N` so vSphere isn't overwhelmed.
#
# Run server + desktop in parallel (one Packer process):
#   packer build -var-file=variables.pkrvars.hcl -parallel-builds=2 -only='ubuntu-2404.*' .
#
# Run a single source:
#   packer build -var-file=variables.pkrvars.hcl -only='ubuntu-2404.vsphere-iso.ubuntu-2404-server'  .
#   packer build -var-file=variables.pkrvars.hcl -only='ubuntu-2404.vsphere-iso.ubuntu-2404-desktop' .
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
  notes         = "Ubuntu 24.04 LTS Server — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
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
  notes         = "Ubuntu 24.04 LTS Desktop — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
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
  # on the same IP (~65-76 min into the build).
  # desktop_ssh_timeout = "120m" covers the full install + reboot window.
  # ip_wait_timeout must remain > ip_settle_timeout.
  ip_wait_timeout   = "120m"
  ip_settle_timeout = "10m"

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

# ── Build ─────────────────────────────────────────────────────────────────────
# Single build with both sources. Packer runs them in parallel when invoked
# with `-parallel-builds=N` (N>=2). Provisioners that only apply to one source
# are scoped with `only = [...]`. Provisioners without `only` apply to every
# source in the build.

build {
  name = "ubuntu-2404"
  sources = [
    "source.vsphere-iso.ubuntu-2404-server",
    "source.vsphere-iso.ubuntu-2404-desktop",
  ]

  # Server: setup.sh first. Split from vmtools.sh because setup.sh runs
  # `apt-get upgrade -y`, which on a fresh GA image can pull in a new systemd
  # whose postinst triggers daemon-reexec — that kills the SSH session
  # (exit 2300218). expect_disconnect=true tells Packer the disconnect is
  # intentional so it reconnects cleanly for vmtools.sh.
  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2404-server"]
    execute_command   = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  # Server: vmtools.sh after setup.sh completes.
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2404-server"]
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  # Desktop: setup.sh first. Same daemon-reexec hazard as the server variant.
  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
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
    only              = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  # Desktop: vmtools.sh after the desktop install completes.
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  # ── Goss smoke tests — server ────────────────────────────────────────────
  # Asserts post-build state before convert_to_template. If goss fails the
  # build fails and the prune step never runs, so a broken template cannot
  # replace a good one.
  provisioner "shell" {
    only   = ["vsphere-iso.ubuntu-2404-server"]
    inline = ["mkdir -p /tmp/goss"]
  }
  provisioner "file" {
    only        = ["vsphere-iso.ubuntu-2404-server"]
    sources     = ["${path.root}/goss/server.yaml"]
    destination = "/tmp/goss/"
  }
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2404-server"]
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/server.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

  # ── Goss smoke tests — desktop ───────────────────────────────────────────
  # desktop.yaml extends server.yaml via gossfile, so both must be present
  # in the same directory on the target.
  provisioner "shell" {
    only   = ["vsphere-iso.ubuntu-2404-desktop"]
    inline = ["mkdir -p /tmp/goss"]
  }
  provisioner "file" {
    only        = ["vsphere-iso.ubuntu-2404-desktop"]
    sources     = ["${path.root}/goss/server.yaml", "${path.root}/goss/desktop.yaml"]
    destination = "/tmp/goss/"
  }
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/desktop.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

  # One manifest covers both sources (entries appear in builds[]).
  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2404.json"
    strip_path = true
  }
}

# =============================================================================
# Ubuntu 26.04 LTS (Plucky Puffin) — Server & Desktop
# =============================================================================
# Server + desktop are defined as two sources inside a single `build {}` block,
# which lets Packer run them in parallel from one runner. The build workflow
# uses `-parallel-builds=2` for combined runs and a `-only` glob to select the
# source(s) to build (e.g. `ubuntu-2604.*` for both, or
# `ubuntu-2604.vsphere-iso.ubuntu-2604-server` for one). See
# .github/workflows/build-templates.yml for the exact invocation. The ISO
# filename is kept current automatically by check-iso-updates.yml.
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

  # Cloud-init / autoinstall seed — same shared template as 22.04 / 24.04.
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2604-server"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
    })
  }
  cd_label = "cidata"

  # Boot — same as 22.04 / 24.04. The defensive workarounds we tried (double
  # spacebar, overlay.metacopy/redirect_dir/index/nfs_export disables) did
  # not address the actual recurring failure mode (subiquity Network module
  # _send_update loop, screenshot-confirmed). They added complexity without
  # adding reliability, so they're gone.
  #
  # ipv6.disable=1 (before `---`): documented upstream fix for the
  # subiquity Network/_send_update CHANGE loop. Each IPv6 address-change
  # event (link-local on boot, SLAAC from router advertisements) fires a
  # netlink CHANGE event; subiquity's network observer processes each
  # one and somehow re-triggers another, looping until ssh_timeout. The
  # `---` separator scopes ipv6.disable=1 to the LIVE INSTALLER kernel
  # only — clones boot with normal IPv6 behaviour. See
  # https://answers.launchpad.net/ubuntu/+source/ubiquity/+question/698383
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  # IP settle — same as 22.04 / 24.04. ssh_timeout capped at 90m by locals.
  ip_settle_timeout = "20m"

  # SSH communicator
  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.ssh_timeout
  ssh_port             = 22

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

  # Cloud-init / autoinstall seed — same shared template as 22.04 / 24.04.
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2604-desktop"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
    })
  }
  cd_label = "cidata"

  # Boot — same as 22.04 / 24.04. See server source comment above.
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  # IP settle — same as 22.04 / 24.04 desktop. ssh_timeout capped at 90m.
  ip_settle_timeout = "10m"

  # SSH communicator
  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.desktop_ssh_timeout
  ssh_port             = 22

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

  # Server: setup.sh first. Split from vmtools.sh because setup.sh runs
  # `apt-get upgrade -y` on a fresh GA image, which can pull in a new systemd
  # whose postinst triggers daemon-reexec — that kills the SSH session
  # (exit 2300218) the same way ubuntu-desktop-minimal does on the desktop
  # variant. expect_disconnect=true tells Packer the disconnect is intentional
  # so it reconnects cleanly for vmtools.sh.
  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2604-server"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  # Server: vmtools.sh after setup.sh completes (and any systemd reexec
  # triggered by the upgrade has settled).
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-server"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  # Desktop: setup.sh first. Same daemon-reexec hazard as the server variant
  # — apt-get upgrade can replace systemd. expect_disconnect=true.
  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
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
    only              = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  # Desktop: vmtools.sh after the desktop install completes.
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  # ── Strip build-only security knobs ──────────────────────────────────────
  # Runs before goss so the spec asserts the actual shipping state of the
  # template (sudoers entry absent, pwauth drop-in absent).
  provisioner "shell" {
    only             = ["vsphere-iso.ubuntu-2604-server", "vsphere-iso.ubuntu-2604-desktop"]
    execute_command  = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = ["BUILD_USERNAME=${var.build_username}"]
    scripts          = ["${path.root}/scripts/finalize.sh"]
  }

  # ── Goss smoke tests — server ────────────────────────────────────────────
  # Asserts post-build state before convert_to_template. If goss fails the
  # build fails and the prune step never runs, so a broken template cannot
  # replace a good one.
  provisioner "shell" {
    only   = ["vsphere-iso.ubuntu-2604-server"]
    inline = ["mkdir -p /tmp/goss"]
  }
  provisioner "file" {
    only        = ["vsphere-iso.ubuntu-2604-server"]
    sources     = ["${path.root}/goss/server.yaml"]
    destination = "/tmp/goss/"
  }
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-server"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
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
    only   = ["vsphere-iso.ubuntu-2604-desktop"]
    inline = ["mkdir -p /tmp/goss"]
  }
  provisioner "file" {
    only        = ["vsphere-iso.ubuntu-2604-desktop"]
    sources     = ["${path.root}/goss/server.yaml", "${path.root}/goss/desktop.yaml"]
    destination = "/tmp/goss/"
  }
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/desktop.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

  # One manifest covers both sources (entries appear in builds[]).
  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2604.json"
    strip_path = true
  }
}

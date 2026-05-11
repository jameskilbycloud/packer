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
  # 26.04 server uses server_2604_ram_mb (default 8 GB), not the shared
  # server_ram_mb (default 4 GB). At 4 GB, subiquity's snap-seeding step
  # hangs intermittently on 26.04 — `Waiting for SSH` stays unsatisfied for
  # the entire ssh_timeout window because the install never finishes the
  # post-seed reboot. 8 GB has reproduced clean builds where 4 GB hangs.
  # Suspected cause: memory-pressure deadlock in subiquity's headless
  # chroot when D-Bus-using snap postinsts run; the live ISO pre-seeds
  # more snaps when more memory is available, but the headless chroot
  # can't satisfy their D-Bus calls.
  CPUs            = 1
  cpu_cores       = var.server_cpu_count
  RAM             = var.server_2604_ram_mb
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

  # Cloud-init / autoinstall seed — 26.04 uses a forked template with the
  # un-nested netplan form, snap-seed dir cleanup, and extra firewall unit
  # masks (see templates/server-2604-user-data.pkrtpl).
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-2604-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2604-server"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
    })
  }
  cd_label = "cidata"

  # Boot — leading <spacebar> halts the GRUB countdown reliably so a slow
  # vSphere console doesn't drop into the default menu entry before we send
  # 'c'. 'c' then opens GRUB's command line where we specify the kernel and
  # initrd explicitly. This avoids the entry editor (e) whose line count
  # varies by ISO. Do NOT use <esc> before 'c' — on EFI GRUB, Escape exits
  # the bootloader entirely.
  #
  # overlay.metacopy=off, overlay.redirect_dir=off: workaround for a kernel
  # oops in ovl_iterate_merged that fires during curtin's image-extract step
  # (rsync from a squashfs-backed OverlayFS mount, exiting with irqs disabled
  # → install hangs). Disabling these two OverlayFS features avoids the
  # buggy code path in 26.04's GA kernel. Live-installer-only — does not
  # affect the installed OS.
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "<spacebar><wait>c<wait3s>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud overlay.metacopy=off overlay.redirect_dir=off<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  # IP settle timeout — kept short so it fires during the live install phase,
  # not after the reboot. Packer starts SSH retries early (hitting ECONNREFUSED
  # while early-commands hold port 22 closed), then connects once the installed
  # OS boots. This works because late-commands copies the live installer's
  # machine-id into the installed OS, giving it the same DUID as the live
  # installer → same DHCP lease → same IP after reboot → Packer's retries
  # succeed.
  # Ubuntu 26.04's install takes longer than 22.04/24.04 (~30-50 min vs ~10 min)
  # so a 20m settle timeout would fire post-install on 22.04/24.04 but mid-install
  # on 26.04. 5m fires consistently during the live phase on all versions.
  # ip_wait_timeout set explicitly (default is 30m) — long enough to cover the
  # VM-power-on → VMware Tools-reports-IP window even on a busy cluster.
  ip_wait_timeout   = "60m"
  ip_settle_timeout = "5m"

  # SSH communicator — 180m covers the full install + reboot + SSH-up window
  # (ip_settle fires at ~5 min; installed OS SSH is up ~40-60 min later, with
  # headroom for first-GA security updates pulled in by setup.sh).
  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.server_2604_ssh_timeout
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

  # Cloud-init / autoinstall seed — 26.04 uses a forked template with the
  # un-nested netplan form, snap-seed dir cleanup, and extra firewall unit
  # masks (see templates/desktop-2604-user-data.pkrtpl).
  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-2604-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2604-desktop"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
    })
  }
  cd_label = "cidata"

  # Boot — leading <spacebar> halts the GRUB countdown reliably so a slow
  # vSphere console doesn't drop into the default menu entry before we send
  # 'c'. 'c' then opens GRUB's command line where we specify the kernel and
  # initrd explicitly. This avoids the entry editor (e) whose line count
  # varies by ISO. Do NOT use <esc> before 'c' — on EFI GRUB, Escape exits
  # the bootloader entirely.
  #
  # overlay.metacopy=off, overlay.redirect_dir=off: workaround for a kernel
  # oops in ovl_iterate_merged that fires during curtin's image-extract step
  # (rsync from a squashfs-backed OverlayFS mount, exiting with irqs disabled
  # → install hangs). Disabling these two OverlayFS features avoids the
  # buggy code path in 26.04's GA kernel. Live-installer-only — does not
  # affect the installed OS.
  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "<spacebar><wait>c<wait3s>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud overlay.metacopy=off overlay.redirect_dir=off<enter><wait5>",
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
  ip_wait_timeout   = "180m"
  ip_settle_timeout = "10m"

  # SSH communicator
  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.desktop_2604_ssh_timeout
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

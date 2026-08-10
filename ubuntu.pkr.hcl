# =============================================================================
# Ubuntu LTS templates — 22.04 / 24.04 / 26.04, Server & Desktop
# =============================================================================
# All three LTS releases live in this single file. Each release contributes a
# server source, a desktop source, and a build block that pairs them. Packer
# merges every *.pkr.hcl file in the root into one graph, so keeping the three
# releases side by side here (rather than in three near-identical files) means
# there is one place to edit and drift between releases is immediately visible.
#
# Everything that genuinely differs between releases — the dotted version used
# in VM notes, the ISO path variable — is centralised in `local.ubuntu` below,
# so the stanzas stay identical apart from a map lookup and the literal release
# token in resource names. A future release is: one `local.ubuntu` entry + a
# server/desktop source pair + a build block that reference it. (Packer HCL
# cannot `for_each` over source/build blocks, so the pair + build block must be
# written out; they must not be collapsed behind a variable without also
# reworking the `-only` targets in build-templates.yml.)
#
# ── Shared design notes (apply to every source below) ────────────────────────
#
# Firmware — EFI without Secure Boot. Secure Boot locks GRUB's edit/command
# keys (e/c) which Packer needs to inject autoinstall kernel parameters. The
# finished template can be redeployed with Secure Boot enabled.
#
# Boot — type 'c' during the GRUB countdown to open the command line, then
# specify the kernel and initrd explicitly. This is version-agnostic and avoids
# the entry editor (e) whose line count varies by ISO. Do NOT use <esc> before
# 'c' — on EFI GRUB, Escape exits the bootloader entirely. `ipv6.disable=1`
# lives before the `---` separator so it applies only to the live installer
# (not the installed OS / clones): it works around the subiquity Network
# observer `_send_update` CHANGE loop where each IPv6 address-change event
# re-triggers the observer until ssh_timeout.
# https://answers.launchpad.net/ubuntu/+source/ubiquity/+question/698383
#
# IP timeouts — the live installer holds a stable IP throughout the install, so
# ip_settle_timeout must outlast the install or it fires on the installer's IP.
# After reboot the installed OS gets a NEW IP (regenerated machine-id → new
# DUID); the settle timer resets and only fires once that IP is stable. Server
# uses a 20m settle; desktop uses 10m (its live installer reports an IP within
# ~40s so Packer starts SSH retries early). ip_wait_timeout is capped at 30m
# for fail-fast — when an install hangs neither IP nor SSH come up, so there's
# no point waiting longer. It must remain > ip_settle_timeout. ssh_timeout is
# set in locals.pkr.hcl (30m server / desktop).
#
# Content Library — each source also publishes its finished template into a
# Content Library as an updatable, portable OVF item. Opt-in: only emitted when
# vsphere_template_content_library is set. The item name is stable (no
# build_date) so repeat builds UPDATE the same item (always-latest), while the
# dated inventory template (convert_to_template) is what rotate/prune manage.
# OVF (not VM-template) items are the ones that can be updated in place.
#
# Build / provisioners — server + desktop run in parallel from one runner when
# invoked with `-parallel-builds=2`; a `-only` glob selects the source(s)
# (e.g. `ubuntu-2604.*`, or `ubuntu-2604.vsphere-iso.ubuntu-2604-server`). See
# build-templates.yml. setup.sh is split from vmtools.sh because its
# `apt-get upgrade -y` can pull in a new systemd whose postinst triggers
# daemon-reexec, killing the SSH session (exit 2300218) — expect_disconnect +
# valid_exit_codes absorb that so Packer reconnects cleanly. desktop.sh has the
# same hazard (ubuntu-desktop-minimal upgrades systemd). finalize.sh strips the
# build-only sudoers/pwauth knobs before goss so the spec asserts the shipping
# state. If goss fails the build fails and prune never runs, so a broken
# template can't replace a good one. desktop.yaml extends server.yaml via
# gossfile, so both are shipped to the desktop target.
# =============================================================================

locals {
  # Per-release metadata. `dotted` is the human version used in VM notes /
  # library descriptions; `iso_path` is the Content Library path resolved by
  # the data sources in data.pkr.hcl, already in the `<library>/<item>/<file>`
  # form that `iso_paths` accepts.
  # The compact release token (2204/2404/2604) stays literal in resource names
  # because Packer source labels and build names must be static strings.
  ubuntu = {
    "2204" = { dotted = "22.04", codename = "Jammy Jellyfish", iso_path = data.vsphere-content-library-item.ubuntu_2204_iso.path }
    "2404" = { dotted = "24.04", codename = "Noble Numbat", iso_path = data.vsphere-content-library-item.ubuntu_2404_iso.path }
    "2604" = { dotted = "26.04", codename = "Resolute Raccoon", iso_path = data.vsphere-content-library-item.ubuntu_2604_iso.path }
  }
}

# =============================================================================
# Ubuntu 22.04 LTS (Jammy Jellyfish)
# =============================================================================

source "vsphere-iso" "ubuntu-2204-server" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name       = "ubuntu-2204-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu ${local.ubuntu["2204"].dotted} LTS Server — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  CPUs            = var.server_cpu_count
  cpu_cores       = 1
  RAM             = var.server_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.server_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_paths = [local.ubuntu["2204"].iso_path]

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2204-server"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
      locale                    = var.locale
      keyboard_layout           = var.keyboard_layout
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  ip_settle_timeout = "20m"

  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.ssh_timeout
  ssh_port             = 22

  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  convert_to_template = true

  dynamic "content_library_destination" {
    for_each = var.vsphere_template_content_library != "" ? [1] : []
    content {
      library     = var.vsphere_template_content_library
      name        = "ubuntu-2204-server"
      description = "Ubuntu ${local.ubuntu["2204"].dotted} LTS Server — Packer ${local.build_timestamp} | git: ${var.git_commit}"
      ovf         = true
    }
  }
}

source "vsphere-iso" "ubuntu-2204-desktop" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name       = "ubuntu-2204-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu ${local.ubuntu["2204"].dotted} LTS Desktop — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  CPUs            = var.desktop_cpu_count
  cpu_cores       = 1
  RAM             = var.desktop_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.desktop_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_paths = [local.ubuntu["2204"].iso_path]

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2204-desktop"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
      locale                    = var.locale
      keyboard_layout           = var.keyboard_layout
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  ip_wait_timeout   = "30m"
  ip_settle_timeout = "10m"

  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.desktop_ssh_timeout
  ssh_port             = 22

  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  convert_to_template = true

  dynamic "content_library_destination" {
    for_each = var.vsphere_template_content_library != "" ? [1] : []
    content {
      library     = var.vsphere_template_content_library
      name        = "ubuntu-2204-desktop"
      description = "Ubuntu ${local.ubuntu["2204"].dotted} LTS Desktop — Packer ${local.build_timestamp} | git: ${var.git_commit}"
      ovf         = true
    }
  }
}

build {
  name = "ubuntu-2204"
  sources = [
    "source.vsphere-iso.ubuntu-2204-server",
    "source.vsphere-iso.ubuntu-2204-desktop",
  ]

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2204-server"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
      "BUILD_USERNAME=${var.build_username}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2204-server"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2204-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
      "BUILD_USERNAME=${var.build_username}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2204-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2204-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  provisioner "shell" {
    only             = ["vsphere-iso.ubuntu-2204-server", "vsphere-iso.ubuntu-2204-desktop"]
    execute_command  = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = ["BUILD_USERNAME=${var.build_username}"]
    scripts          = ["${path.root}/scripts/finalize.sh"]
  }

  provisioner "shell" {
    only   = ["vsphere-iso.ubuntu-2204-server"]
    inline = ["mkdir -p /tmp/goss"]
  }
  provisioner "file" {
    only        = ["vsphere-iso.ubuntu-2204-server"]
    sources     = ["${path.root}/goss/server.yaml"]
    destination = "/tmp/goss/"
  }
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2204-server"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/server.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

  provisioner "shell" {
    only   = ["vsphere-iso.ubuntu-2204-desktop"]
    inline = ["mkdir -p /tmp/goss"]
  }
  provisioner "file" {
    only        = ["vsphere-iso.ubuntu-2204-desktop"]
    sources     = ["${path.root}/goss/server.yaml", "${path.root}/goss/desktop.yaml"]
    destination = "/tmp/goss/"
  }
  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2204-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/desktop.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2204.json"
    strip_path = true
  }
}

# =============================================================================
# Ubuntu 24.04 LTS (Noble Numbat)
# =============================================================================

source "vsphere-iso" "ubuntu-2404-server" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name       = "ubuntu-2404-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu ${local.ubuntu["2404"].dotted} LTS Server — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  CPUs            = var.server_cpu_count
  cpu_cores       = 1
  RAM             = var.server_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.server_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_paths = [local.ubuntu["2404"].iso_path]

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2404-server"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
      locale                    = var.locale
      keyboard_layout           = var.keyboard_layout
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  ip_settle_timeout = "20m"

  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.ssh_timeout
  ssh_port             = 22

  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  convert_to_template = true

  dynamic "content_library_destination" {
    for_each = var.vsphere_template_content_library != "" ? [1] : []
    content {
      library     = var.vsphere_template_content_library
      name        = "ubuntu-2404-server"
      description = "Ubuntu ${local.ubuntu["2404"].dotted} LTS Server — Packer ${local.build_timestamp} | git: ${var.git_commit}"
      ovf         = true
    }
  }
}

source "vsphere-iso" "ubuntu-2404-desktop" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name       = "ubuntu-2404-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu ${local.ubuntu["2404"].dotted} LTS Desktop — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  CPUs            = var.desktop_cpu_count
  cpu_cores       = 1
  RAM             = var.desktop_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.desktop_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_paths = [local.ubuntu["2404"].iso_path]

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2404-desktop"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
      locale                    = var.locale
      keyboard_layout           = var.keyboard_layout
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  ip_wait_timeout   = "30m"
  ip_settle_timeout = "10m"

  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.desktop_ssh_timeout
  ssh_port             = 22

  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  convert_to_template = true

  dynamic "content_library_destination" {
    for_each = var.vsphere_template_content_library != "" ? [1] : []
    content {
      library     = var.vsphere_template_content_library
      name        = "ubuntu-2404-desktop"
      description = "Ubuntu ${local.ubuntu["2404"].dotted} LTS Desktop — Packer ${local.build_timestamp} | git: ${var.git_commit}"
      ovf         = true
    }
  }
}

build {
  name = "ubuntu-2404"
  sources = [
    "source.vsphere-iso.ubuntu-2404-server",
    "source.vsphere-iso.ubuntu-2404-desktop",
  ]

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2404-server"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
      "BUILD_USERNAME=${var.build_username}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2404-server"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
      "BUILD_USERNAME=${var.build_username}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2404-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  provisioner "shell" {
    only             = ["vsphere-iso.ubuntu-2404-server", "vsphere-iso.ubuntu-2404-desktop"]
    execute_command  = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = ["BUILD_USERNAME=${var.build_username}"]
    scripts          = ["${path.root}/scripts/finalize.sh"]
  }

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
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/server.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

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
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = [
      "BUILD_USERNAME=${var.build_username}",
      "GOSS_SPEC=/tmp/goss/desktop.yaml",
    ]
    scripts = ["${path.root}/scripts/goss-validate.sh"]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2404.json"
    strip_path = true
  }
}

# =============================================================================
# Ubuntu 26.04 LTS (Resolute Raccoon)
# =============================================================================
# Historical note: the 26.04 boot_command previously carried `toram` plus five
# `overlay.*=off / xino_auto=on` knobs as probability-lowering mitigations for
# the LP #2150586 ovl_iterate_merged kernel oops. All six were validated
# redundant once `source.id: ubuntu-server-minimal` (in the autoinstall
# templates) structurally bypassed the bug at the curtin layer. See the commit
# history if a future point release reintroduces a related install failure.

source "vsphere-iso" "ubuntu-2604-server" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name       = "ubuntu-2604-server-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu ${local.ubuntu["2604"].dotted} LTS Server — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  CPUs            = var.server_cpu_count
  cpu_cores       = 1
  RAM             = var.server_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.server_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_paths = [local.ubuntu["2604"].iso_path]

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/server-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2604-server"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
      locale                    = var.locale
      keyboard_layout           = var.keyboard_layout
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  ip_settle_timeout = "20m"

  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.ssh_timeout
  ssh_port             = 22

  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  convert_to_template = true

  dynamic "content_library_destination" {
    for_each = var.vsphere_template_content_library != "" ? [1] : []
    content {
      library     = var.vsphere_template_content_library
      name        = "ubuntu-2604-server"
      description = "Ubuntu ${local.ubuntu["2604"].dotted} LTS Server — Packer ${local.build_timestamp} | git: ${var.git_commit}"
      ovf         = true
    }
  }
}

source "vsphere-iso" "ubuntu-2604-desktop" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_user
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster != "" ? var.vsphere_cluster : null
  host       = var.vsphere_host != "" ? var.vsphere_host : null
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name       = "ubuntu-2604-desktop-${local.build_date}"
  guest_os_type = "ubuntu64Guest"
  notes         = "Ubuntu ${local.ubuntu["2604"].dotted} LTS Desktop — built by Packer on ${local.build_timestamp} | git: ${var.git_commit}"
  vm_version    = var.vm_hardware_version

  CPUs            = var.desktop_cpu_count
  cpu_cores       = 1
  RAM             = var.desktop_ram_mb
  RAM_reserve_all = false

  firmware = "efi"

  disk_controller_type = ["pvscsi"]
  storage {
    disk_size             = var.desktop_disk_gb * 1024
    disk_thin_provisioned = true
    disk_controller_index = 0
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_paths = [local.ubuntu["2604"].iso_path]

  cd_content = {
    "meta-data" = ""
    "user-data" = templatefile("${path.root}/templates/desktop-user-data.pkrtpl", {
      vm_hostname               = "ubuntu-2604-desktop"
      build_username            = var.build_username
      build_password_encrypted  = var.build_password_encrypted
      build_ssh_authorized_keys = var.build_ssh_authorized_keys
      timezone                  = var.timezone
      locale                    = var.locale
      keyboard_layout           = var.keyboard_layout
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "c<wait2>",
    "linux /casper/vmlinuz ipv6.disable=1 --- autoinstall ds=nocloud<enter><wait5>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter><wait30>"
  ]

  ip_wait_timeout   = "30m"
  ip_settle_timeout = "10m"

  communicator         = "ssh"
  ssh_username         = var.build_username
  ssh_password         = var.build_password
  ssh_private_key_file = var.build_ssh_private_key_file != "" ? var.build_ssh_private_key_file : null
  ssh_timeout          = local.desktop_ssh_timeout
  ssh_port             = 22

  shutdown_command = "echo '${var.build_password}' | sudo -S shutdown -P now"
  shutdown_timeout = local.shutdown_timeout

  convert_to_template = true

  dynamic "content_library_destination" {
    for_each = var.vsphere_template_content_library != "" ? [1] : []
    content {
      library     = var.vsphere_template_content_library
      name        = "ubuntu-2604-desktop"
      description = "Ubuntu ${local.ubuntu["2604"].dotted} LTS Desktop — Packer ${local.build_timestamp} | git: ${var.git_commit}"
      ovf         = true
    }
  }
}

build {
  name = "ubuntu-2604"
  sources = [
    "source.vsphere-iso.ubuntu-2604-server",
    "source.vsphere-iso.ubuntu-2604-desktop",
  ]

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2604-server"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
      "BUILD_USERNAME=${var.build_username}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-server"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    environment_vars = [
      "ADMIN_USERNAME=${var.admin_username}",
      "ADMIN_GITHUB_USER=${var.admin_github_user}",
      "BUILD_USERNAME=${var.build_username}",
    ]
    scripts = ["${path.root}/scripts/setup.sh"]
  }

  provisioner "shell" {
    only              = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command   = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    scripts           = ["${path.root}/scripts/desktop.sh"]
  }

  provisioner "shell" {
    only            = ["vsphere-iso.ubuntu-2604-desktop"]
    execute_command = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    scripts         = ["${path.root}/scripts/vmtools.sh"]
  }

  provisioner "shell" {
    only             = ["vsphere-iso.ubuntu-2604-server", "vsphere-iso.ubuntu-2604-desktop"]
    execute_command  = "echo '${var.build_password}' | sudo -S env {{.Vars}} bash {{.Path}}"
    environment_vars = ["BUILD_USERNAME=${var.build_username}"]
    scripts          = ["${path.root}/scripts/finalize.sh"]
  }

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

  post-processor "manifest" {
    output     = "${path.root}/manifests/ubuntu-2604.json"
    strip_path = true
  }
}

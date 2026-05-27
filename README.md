# Packer — vSphere Templates

## Quality checks

[![Build Packer Templates](https://github.com/jameskilbycloud/packer/actions/workflows/build-templates.yml/badge.svg)](https://github.com/jameskilbycloud/packer/actions/workflows/build-templates.yml)
[![Validate](https://github.com/jameskilbycloud/packer/actions/workflows/validate.yml/badge.svg)](https://github.com/jameskilbycloud/packer/actions/workflows/validate.yml)
[![Pre-commit](https://github.com/jameskilbycloud/packer/actions/workflows/pre-commit.yml/badge.svg)](https://github.com/jameskilbycloud/packer/actions/workflows/pre-commit.yml)
[![Check ISO updates](https://github.com/jameskilbycloud/packer/actions/workflows/check-iso-updates.yml/badge.svg)](https://github.com/jameskilbycloud/packer/actions/workflows/check-iso-updates.yml)
[![Rotate templates](https://github.com/jameskilbycloud/packer/actions/workflows/rotate-templates.yml/badge.svg)](https://github.com/jameskilbycloud/packer/actions/workflows/rotate-templates.yml)

Automated golden-image pipeline that builds Ubuntu VM templates directly in vSphere using [HashiCorp Packer](https://www.packer.io/). Supports three Ubuntu LTS versions (22.04, 24.04, 26.04) with server and desktop variants — six templates in total.

---

## How it works

```
Upload ISOs ──► packer init ──► packer build ──► vSphere Template
(upload-isos.sh)                (vsphere-iso)    (ready to clone)
```

1. **ISO upload** — `scripts/upload-isos.sh` downloads Ubuntu ISOs from `releases.ubuntu.com`, verifies their SHA256 checksums, and imports them into a vSphere Content Library.
2. **Packer build** — the `vsphere-iso` builder boots a VM from the ISO and attaches a secondary CD (labelled `cidata`) carrying the cloud-init autoinstall `user-data`.
3. **Provisioning** — shell provisioners run `setup.sh` / `vmtools.sh` (and `desktop.sh` for desktop variants) inside the VM.
4. **Template conversion** — the finished VM is converted to a vSphere template in-place.

Autoinstall configuration is rendered at build time via HCL's `templatefile()` function, so credentials are injected from your variables file rather than baked into static files.

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| [Packer](https://developer.hashicorp.com/packer/install) | 1.10.0 | `brew install packer` or download binary |
| [govc](https://github.com/vmware/govmomi/releases) | any recent | Required for ISO upload only |
| curl | any | ISO download |
| sha256sum / shasum | any | Checksum verification (pre-installed on Linux/macOS) |
| vCenter | 7.0+ | ESXi standalone also works with minor config changes |

The machine running Packer must be able to reach the vCenter API (port 443) and the VM's SSH port (22) on the VM network during the build.

---

## Project structure

```
packer/
├── packer.pkr.hcl                  # Plugin requirements (vsphere ≥ 2.1.2 from vmware/vsphere)
├── variables.pkr.hcl               # All variable declarations with descriptions
├── locals.pkr.hcl                  # Shared locals: build_date, build_timestamp
│
├── ubuntu-2204.pkr.hcl             # 22.04 server + desktop sources and builds
├── ubuntu-2404.pkr.hcl             # 24.04 server + desktop sources and builds
├── ubuntu-2604.pkr.hcl             # 26.04 server + desktop sources and builds
│
├── templates/
│   ├── server-user-data.pkrtpl              # Cloud-init autoinstall — Ubuntu server (22/24)
│   ├── desktop-user-data.pkrtpl             # Cloud-init autoinstall — Ubuntu desktop (22/24)
│   ├── server-2604-user-data.pkrtpl         # Cloud-init autoinstall — Ubuntu 26.04 server
│   └── desktop-2604-user-data.pkrtpl        # Cloud-init autoinstall — Ubuntu 26.04 desktop
│
├── scripts/
│   ├── upload-isos.sh              # Download Ubuntu ISOs and import to Content Library
│   ├── setup.sh                    # Ubuntu: apt upgrade, SSH hardening
│   ├── vmtools.sh                  # Ubuntu: verify open-vm-tools
│   └── desktop.sh                  # Ubuntu desktop-only: ubuntu-desktop-minimal install
│
├── variables.pkrvars.hcl.example   # Copy this → variables.pkrvars.hcl and fill in
├── Makefile                        # Convenience build targets
└── manifests/                      # Build manifests written here after each run
```

All `.pkr.hcl` files in the root are combined by Packer into a single build graph. Use `-only=` to target a specific build (see [Running builds](#running-builds)).

---

## Quick start

### 1. Install the vSphere plugin

```bash
make init
# equivalent to: packer init .
```

### 2. Configure your variables

```bash
cp variables.pkrvars.hcl.example variables.pkrvars.hcl
```

Edit `variables.pkrvars.hcl` with your vSphere details and credentials. See [Variable reference](#variable-reference) for every option.

> **Important:** `variables.pkrvars.hcl` contains credentials and must never be committed. The `.gitignore` already covers `*.pkrvars.hcl` so the file is ignored automatically — no extra steps needed.

### 3. Generate the build password hash

The autoinstall user-data requires a SHA-512 hashed password. Generate one and paste it into `variables.pkrvars.hcl`:

```bash
openssl passwd -6 'YourBuildPassword'
```

Set both fields in the vars file:

```hcl
build_password           = "YourBuildPassword"       # plaintext — for SSH connection
build_password_encrypted = "$6$salt$hash..."          # output of openssl passwd -6
```

### 4. Upload ISOs to vSphere

Set your govc environment and run the upload script:

```bash
export GOVC_URL="https://vcenter.example.com"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="secret"
export GOVC_DATACENTER="Datacenter"
export LIBRARY_DATASTORE="datastore1"

make upload-isos
```

The script creates a Content Library called `Packer-ISOs` (configurable), downloads each ISO with checksum verification, and imports it. It prints the exact variable values to copy into your vars file when done.

See [ISO upload in detail](#iso-upload-in-detail) for all options.

### 5. Validate

```bash
make validate
```

### 6. Build

```bash
# Build one image
make 2404-server

# Build all six images (sequential)
make build-all
```

---

## ISO upload in detail

`scripts/upload-isos.sh` is controlled entirely by environment variables.

| Variable | Required | Default | Description |
|---|---|---|---|
| `GOVC_URL` | yes | — | vCenter URL, e.g. `https://vcenter.example.com` |
| `GOVC_USERNAME` | yes | — | vCenter username |
| `GOVC_PASSWORD` | yes | — | vCenter password |
| `GOVC_INSECURE` | no | `false` | Skip TLS verification |
| `GOVC_DATACENTER` | yes | — | Datacenter name |
| `LIBRARY_DATASTORE` | yes | — | Datastore to back the Content Library |
| `CONTENT_LIBRARY` | no | `Packer-ISOs` | Content Library name to create or reuse |
| `UBUNTU_VERSIONS` | no | `2204 2404 2604` | Space-separated versions to process |
| `DOWNLOAD_DIR` | no | `/var/tmp/packer-isos` | Local directory for ISO downloads |
| `KEEP_DOWNLOADS` | no | `false` | Set `true` to keep local ISOs after upload |
| `SKIP_CHECKSUM` | no | `false` | Set `true` to skip SHA256 verification |

**Examples:**

```bash
# Upload a single version
UBUNTU_VERSIONS="2404" make upload-isos

# Keep ISOs locally (useful if you need to upload to multiple vCenters)
KEEP_DOWNLOADS=true make upload-isos

# Use a custom library name
CONTENT_LIBRARY=Ubuntu-ISOs make upload-isos

# Skip checksum verification (not recommended)
SKIP_CHECKSUM=true make upload-isos
```

The script is idempotent — if an ISO is already present in the library it is skipped, so it is safe to re-run after a partial failure.

### ISO sources

| Version | ISO | Checksum |
|---|---|---|
| 22.04 LTS | [ubuntu-22.04.5-live-server-amd64.iso](https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso) | [SHA256SUMS](https://releases.ubuntu.com/22.04/SHA256SUMS) |
| 24.04 LTS | [ubuntu-24.04.4-live-server-amd64.iso](https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso) | [SHA256SUMS](https://releases.ubuntu.com/24.04/SHA256SUMS) |
| 26.04 LTS | [releases.ubuntu.com/26.04](https://releases.ubuntu.com/26.04/) | [SHA256SUMS](https://releases.ubuntu.com/26.04/SHA256SUMS) |

> **Note on 26.04:** Ubuntu 26.04 was released in April 2026. If the ISO filename differs from the placeholder in the script, update `ISO_FILENAME[2604]` near the top of `scripts/upload-isos.sh`.

All builds use the **live-server ISO** for both server and desktop images. The desktop environment (`ubuntu-desktop-minimal`) is installed by the `desktop.sh` provisioner after the OS install completes — there is no separate desktop ISO to manage.

---

## Variable reference

All variables are declared in `variables.pkr.hcl`. Set them in `variables.pkrvars.hcl`.

### vSphere connection

| Variable | Required | Default | Description |
|---|---|---|---|
| `vsphere_server` | yes | — | vCenter hostname or IP |
| `vsphere_user` | yes | — | vCenter username |
| `vsphere_password` | yes | — | vCenter password (sensitive) |
| `vsphere_insecure_connection` | no | `false` | Skip TLS verification |

### vSphere infrastructure

| Variable | Required | Default | Description |
|---|---|---|---|
| `vsphere_datacenter` | yes | — | Datacenter name |
| `vsphere_cluster` | no | `""` | Cluster name. Leave empty if targeting a host directly |
| `vsphere_host` | no | `""` | ESXi host. Required if `vsphere_cluster` is empty |
| `vsphere_datastore` | yes | — | Datastore for VM storage |
| `vsphere_network` | yes | — | Port group / network name for the VM NIC |
| `vsphere_folder` | no | `"packer"` | VM folder path for finished templates |
| `vsphere_iso_datastore` | yes | — | Datastore **or** Content Library name holding the ISOs |

### Build credentials

| Variable | Required | Default | Description |
|---|---|---|---|
| `build_username` | no | `"ubuntu"` | Admin user created during install |
| `build_password` | yes | — | Plaintext password for SSH during build (sensitive) |
| `build_password_encrypted` | yes | — | SHA-512 hash for autoinstall user-data. Generate: `openssl passwd -6 '<password>'` |

### VM hardware — server

| Variable | Default | Description |
|---|---|---|
| `server_cpu_count` | `2` | vCPU cores |
| `server_ram_mb` | `4096` | RAM in MB (22.04 / 24.04 server) |
| `server_2604_ram_mb` | `8192` | RAM in MB (26.04 server only — see note) |
| `server_disk_gb` | `40` | OS disk size in GB |

> **26.04 server RAM**: subiquity's snap-seeding step hangs intermittently on 26.04 at 4 GB — the install never reaches the post-seed reboot and the build burns the full `ssh_timeout` budget at "Waiting for SSH". 8 GB has reproduced clean builds. 22.04 / 24.04 don't exhibit this and stay at 4 GB.

### VM hardware — desktop

| Variable | Default | Description |
|---|---|---|
| `desktop_cpu_count` | `4` | vCPU cores |
| `desktop_ram_mb` | `8192` | RAM in MB |
| `desktop_disk_gb` | `60` | OS disk size in GB |

### VM hardware — general

| Variable | Default | Description |
|---|---|---|
| `vm_hardware_version` | `19` | VMware hardware version. 19 = vSphere 7.0 U2, 20 = vSphere 8.0, 21 = vSphere 8.0 U2 |

### ISO paths

| Variable | Default | Description |
|---|---|---|
| `ubuntu_2204_iso_path` | `ISOs/ubuntu-22.04.5-live-server-amd64.iso` | Path within the datastore, or filename if using a Content Library |
| `ubuntu_2404_iso_path` | `ISOs/ubuntu-24.04.4-live-server-amd64.iso` | As above for 24.04 |
| `ubuntu_2604_iso_path` | `ISOs/ubuntu-26.04-live-server-amd64.iso` | As above for 26.04 |

**Datastore vs Content Library:** the `vsphere_iso_datastore` variable accepts either a datastore name or a Content Library name — the vSphere bracket notation `[name]` works identically for both. When pointing at a Content Library, the ISO path should be just the filename with no subfolder prefix.

---

## Running builds

All builds are run from the repository root. Packer combines every `.pkr.hcl` file in the directory; use `-only=` to target a specific source.

### Via Makefile (recommended)

```bash
make 2204-server     # Ubuntu 22.04 Server
make 2204-desktop    # Ubuntu 22.04 Desktop
make 2404-server     # Ubuntu 24.04 Server
make 2404-desktop    # Ubuntu 24.04 Desktop
make 2604-server     # Ubuntu 26.04 Server
make 2604-desktop    # Ubuntu 26.04 Desktop

make 2204            # Both 22.04 images
make 2404            # Both 24.04 images
make 2604            # Both 26.04 images
make build-all       # All Ubuntu images (sequential)
```

### Via Packer directly

Packer's `-only` flag requires the full `<build-label>.<source-type>.<source-name>` reference. Use a glob to avoid hard-coding the build label:

```bash
packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2404-server' .
```

### Useful flags

```bash
# Validate without building
packer validate -var-file=variables.pkrvars.hcl .

# Enable debug output
PACKER_LOG=1 packer build -var-file=variables.pkrvars.hcl -only='*.vsphere-iso.ubuntu-2404-server' .

# Destroy the VM on failure instead of leaving it running
packer build -on-error=cleanup -var-file=variables.pkrvars.hcl .
```

### Build outputs

Each build produces:
- A **vSphere template** in the folder specified by `vsphere_folder`, named `ubuntu-<version>-<type>-<YYYYMMDD>` (e.g. `ubuntu-2404-server-20260429`)
- A **manifest JSON** in `manifests/` recording the template name and build metadata

---

## VM specifications

### Server images

| Setting | Value |
|---|---|
| OS | Ubuntu Server (minimal) |
| vCPUs | 2 (1 socket × 2 cores) |
| RAM | 4 GB (22.04 / 24.04), 8 GB (26.04) |
| Disk | 40 GB thin-provisioned (LVM) |
| Network | vmxnet3, DHCP |
| Firmware | EFI (Secure Boot disabled — needed so Packer can inject autoinstall args via the GRUB command line) |
| Extra packages | open-vm-tools, curl, wget, vim, git, net-tools (installed by `setup.sh` / `vmtools.sh`, not autoinstall) |

### Desktop images

| Setting | Value |
|---|---|
| OS | Ubuntu Desktop (ubuntu-desktop-minimal + GNOME) |
| vCPUs | 4 (1 socket × 4 cores) |
| RAM | 8 GB |
| Disk | 60 GB thin-provisioned (LVM) |
| Network | vmxnet3, DHCP |
| Firmware | EFI (Secure Boot disabled) |
| Extra packages | open-vm-tools, open-vm-tools-desktop, ubuntu-desktop-minimal, curl, wget, vim, git (installed by `setup.sh` / `desktop.sh` / `vmtools.sh`, not autoinstall) |

All sizes are configurable via variables.

---

## What gets installed

### OS install (autoinstall / cloud-init)

The autoinstall seed is written to a small ISO (labelled `cidata`) at build time via Packer's `cd_content` mechanism. No HTTP server is required — vSphere mounts the seed disc directly. The installer runs fully unattended and powers off the VM when complete.

Key autoinstall steps:
- LVM storage layout on the first available disk
- SSH server enabled (`allow-pw: true`) so Packer can connect
- Passwordless sudo granted to the build user for provisioner scripts
- `datasource_list: [None]` written to `/etc/cloud/cloud.cfg.d/99-packer.cfg` — neutralises cloud-init on cloned VMs without disabling its systemd units (the older `cloud-init.disabled` approach broke 24.04 networking because cloud-init's boot units are in the dependency chain)
- UFW disabled and the unit masked to `/dev/null` so the firewall does not block SSH on first boot of clones

`packages: []` and `snaps: []` are explicitly empty — every package or snap that needs `systemctl` or D-Bus during install would deadlock inside subiquity's headless chroot on 26.04, so all post-install work is moved to the shell provisioners below.

### Shell provisioners (`scripts/`)

**`setup.sh`** — runs after the OS install completes (every variant):
- `apt-get update && apt-get upgrade` (full security upgrade)
- Installs common utilities (curl, wget, vim, git, net-tools, etc.)
- Disables swap and tunes `vm.swappiness`
- Removes SSH host keys, then installs a oneshot `ssh-host-keygen.service` systemd unit that regenerates them before `ssh.socket` / `ssh.service` on the first boot of each clone (needed because socket-activated SSH on 22.04+ never triggers `ssh-keygen@.service`)
- Installs a oneshot `firstboot-hostname.service` that appends a 6-hex-char suffix derived from the vSphere VM UUID to the hostname (e.g. `ubuntu-2604-server-3a4f5b`) on the first boot of each clone — stable across reboots of the same VM, unique across clones. Avoids DNS / monitoring / Slack collisions when multiple clones boot on the same network. Runs before `network-pre.target` so DHCP announces the unique name; disables itself after the first successful run via a sentinel at `/var/lib/packer-firstboot/hostname.done`.
- Appends SSH hardening config (`PermitRootLogin no`, etc.)
- Truncates `/etc/machine-id` so each clone gets a fresh ID + DHCP lease
- Optionally creates a persistent admin user and imports SSH keys via `ssh-import-id-gh`
- Zeroes free disk space for smaller template storage footprint

**`desktop.sh`** — runs only for the desktop variants, after `setup.sh`:
- Installs `ubuntu-desktop-minimal` and `open-vm-tools-desktop`
- Holds snap auto-refresh for 60 days so it does not race with the remaining provisioners

**`vmtools.sh`** — runs last (every variant):
- Installs `open-vm-tools` if not already present
- Installs `open-vm-tools-desktop` if a display manager is detected
- Enables and starts the service
- Reports the running version

---

## Customisation

### Adding Ansible provisioning

Replace or supplement the shell provisioners in any build block:

```hcl
provisioner "ansible" {
  playbook_file   = "${path.root}/ansible/site.yml"
  user            = var.build_username
  use_proxy       = false
  ansible_env_vars = [
    "ANSIBLE_HOST_KEY_CHECKING=False"
  ]
}
```

Requires the `ansible` Packer plugin — add to `packer.pkr.hcl`:

```hcl
ansible = {
  version = ">= 1.1.0"
  source  = "github.com/hashicorp/ansible"
}
```

### Static IP instead of DHCP

Edit the network section in the relevant `templates/*-user-data.pkrtpl`. The 22.04 / 24.04 templates use the legacy doubly-nested form (`network: { network: { version: 2, ... } }`); the 26.04 templates use the single-level form documented by current subiquity.

For 22.04 / 24.04 (`templates/{server,desktop}-user-data.pkrtpl`):

```yaml
network:
  network:
    version: 2
    ethernets:
      ens192:
        dhcp4: false
        addresses: [192.168.1.50/24]
        gateway4: 192.168.1.1
        nameservers:
          addresses: [1.1.1.1, 8.8.8.8]
```

For 26.04 (`templates/{server,desktop}-2604-user-data.pkrtpl`):

```yaml
network:
  version: 2
  ethernets:
    ens192:
      dhcp4: false
      addresses: [192.168.1.50/24]
      gateway4: 192.168.1.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

### Different storage layout

Replace the `storage` block in the user-data template. For example, to use a direct (non-LVM) layout:

```yaml
storage:
  layout:
    name: direct
```

Or to add a separate `/data` partition, use the full `storage` config syntax documented at [ubuntu.com/server/docs/install/autoinstall-reference](https://ubuntu.com/server/docs/install/autoinstall-reference).

### Adjusting VM hardware

Override any of the hardware variables in `variables.pkrvars.hcl`:

```hcl
server_cpu_count = 4
server_ram_mb    = 4096
server_disk_gb   = 80
```

### Storing templates in a Content Library

To output finished templates to a Content Library instead of the standard VM inventory, add a `content_library_destination` block to the source:

```hcl
content_library_destination {
  library = "My-Template-Library"
  ovf     = true
  destroy = true   # removes the VM after exporting to the library
}
```

---

## Operations

Day-to-day operation runs from GitHub Actions: PRs validate, scheduled crons rebuild and rotate, a post-publish smoke job exercises every new template, and a weekly check opens a PR when Ubuntu releases a new point ISO.

The full operator reference — self-hosted runner setup, required vSphere + GitHub Actions permissions, per-workflow detail, build lifecycle, and troubleshooting — lives in **[docs/operations.md](docs/operations.md)**.

After completing the [Quick start](#quick-start) above, the typical setup path is:

1. Register a self-hosted runner — see [Why a self-hosted runner](docs/operations.md#why-a-self-hosted-runner) and [Setting up the runner](docs/operations.md#setting-up-the-runner).
2. Grant the Packer service account the [required vCenter privileges](docs/operations.md#vsphere) and enable the [GitHub Actions toggles](docs/operations.md#github-actions).
3. Populate secrets with `make secrets` — see [GitHub Secrets](docs/operations.md#github-secrets).
4. Trigger `upload-isos.yml` once to seed the Content Library.
5. Trigger your first build from the Actions tab.

---

## Security notes

- `variables.pkrvars.hcl` contains credentials — never commit it. The `.gitignore` entry is set up in the quick start.
- The build user is granted passwordless sudo during the build. `setup.sh` does **not** remove this — if you want to lock it down in the final template, add a `late-commands` step or a provisioner that removes `/etc/sudoers.d/90-packer-${build_username}`.
- SSH host keys are wiped by `setup.sh` and regenerated on the first boot of each cloned VM by a oneshot systemd unit (`ssh-host-keygen.service`) that runs before `ssh.socket` and `ssh.service`, then disables itself. This works around the fact that 22.04+ socket-activated SSH never triggers the stock `ssh-keygen@.service`.
- Cloud-init is neutralised on cloned VMs via `/etc/cloud/cloud.cfg.d/99-packer.cfg` containing `datasource_list: [None]` (a no-op datasource). Cloud-init's systemd units still run but do nothing — they are intentionally **not** disabled because cloud-init's boot units are in the dependency chain on 24.04 and disabling them breaks networking. To re-enable cloud-init in your deployment workflow, remove that file.

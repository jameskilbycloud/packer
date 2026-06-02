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
├── packer.pkr.hcl                  # Plugin requirements (vsphere ≥ 2.1.2)
├── variables.pkr.hcl               # All variable declarations + defaults
├── locals.pkr.hcl                  # Shared locals: build_date, ssh_timeout
│
├── ubuntu-2204.pkr.hcl             # 22.04 server + desktop sources
├── ubuntu-2404.pkr.hcl             # 24.04 server + desktop sources
├── ubuntu-2604.pkr.hcl             # 26.04 server + desktop sources
│
├── templates/
│   ├── server-user-data.pkrtpl     # Cloud-init autoinstall (server, all versions)
│   └── desktop-user-data.pkrtpl    # Cloud-init autoinstall (desktop, all versions)
│
├── scripts/
│   ├── upload-isos.sh              # Download ISOs → Content Library (called by upload-isos.yml)
│   ├── check-iso-updates.sh        # Detect new Ubuntu point releases; --apply rewrites refs
│   ├── setup.sh                    # Post-install: upgrade, SSH hardening, host key wipe
│   ├── finalize.sh                 # Last provisioner: remove build-time pwauth + sudoers drop-ins
│   ├── vmtools.sh                  # Verify / install open-vm-tools
│   ├── desktop.sh                  # Desktop-only: ubuntu-desktop-minimal install
│   ├── goss-validate.sh            # Goss smoke runner (in-build + post-publish)
│   ├── smoke-test.sh               # Clone just-built template, boot, re-run goss
│   └── prune-templates.sh          # Retention policy: keep last N per (version, role)
│
├── goss/
│   ├── server.yaml                 # Post-build assertions (universal)
│   └── desktop.yaml                # Desktop-only additions (gossfile-includes server.yaml)
│
├── docs/
│   └── operations.md               # Operator reference: runner, perms, workflows, troubleshooting
│
├── manifests/                      # Build manifests written here after each run
│
└── .github/workflows/
    ├── validate.yml                # PR fmt + packer validate
    ├── pre-commit.yml              # Pre-commit hooks (gitleaks, yamllint, shellcheck, …)
    ├── build-templates.yml         # Packer build + post-publish smoke + prune
    ├── upload-isos.yml             # ISO uploads, manual + auto-dispatched
    ├── check-iso-updates.yml       # Mon 06:00 UTC: bump PR + auto-upload on drift
    └── rotate-templates.yml        # 1st of month 03:00 UTC: prune all groups
```

All `.pkr.hcl` files in the root are combined by Packer into a single build graph; the `build-templates` workflow uses `-only=` to target a specific source.

---

## Deploy from scratch — GitHub-only

Every step happens in the GitHub web UI, your vCenter, or a single self-hosted runner VM. No local checkout, no local Packer install, no credentials file on a workstation.

### Prerequisites (one-time, outside GitHub)

Four things must exist before GitHub can drive the pipeline:

1. **A dedicated vCenter SSO user** (e.g. `packer@vsphere.local`) with the privileges listed in [docs/operations.md → vSphere](docs/operations.md#vsphere). `Administrator` works for first-time setup; the minimum role is more restrictive. Grant the role at the Datacenter (or Cluster) level with **Propagate to children**, and separately at the Content Library that will hold the ISOs.
2. **A small Ubuntu VM inside your vSphere network** to host the GitHub self-hosted runner (~2 vCPU / 4 GB RAM / 20 GB disk). The runner dials *out* — no inbound firewall rules needed — but it does need outbound 443 to `github.com` + `*.actions.githubusercontent.com`, outbound 443 to your vCenter, and outbound 22 to the VM network so Packer can SSH into builds and the smoke test can SSH into clones. `curl`, `git`, `python3`, and `perl` should be on PATH (default on Ubuntu Server).
3. **DHCP on the target VM network.** Packer-built VMs come up via DHCP — the autoinstall config doesn't pin static IPs. The smoke test also relies on the cloned VM getting a DHCP lease so VMware Tools can report an IP back. If you only have static addressing available, switch to a network with DHCP for builds (templates clone fine onto static-IP networks afterwards).
4. **Admin access to the GitHub repo where the pipeline runs.** You need Settings access to add secrets, register the runner, toggle workflow permissions, and trigger workflow dispatches. A user account with the **Maintain** role is enough; **Admin** is needed for Org-level runner registration.

### 1. Fork the repo

Click **Fork** on github.com. The workflows ship with the repo so they're enabled immediately on your copy.

### 2. Enable GitHub Actions permissions

**Settings → Actions → General → Workflow permissions:**

- Set to **Read and write permissions**
- Tick **Allow GitHub Actions to create and approve pull requests**

Without these, `check-iso-updates` can't open the weekly bump PR or auto-dispatch the upload. See [docs/operations.md → GitHub Actions permissions](docs/operations.md#github-actions) for the per-workflow detail.

### 3. Register the self-hosted runner

**Settings → Actions → Runners → New self-hosted runner.** GitHub displays a setup script — paste it into a terminal on the runner VM from the prerequisites.

For zero-sudo operation, also pre-install `packer`, `xorriso`, and `govc` as root one time on the runner. The exact commands are in [docs/operations.md → Setting up the runner](docs/operations.md#setting-up-the-runner). The workflows skip the install steps if these binaries are already on PATH.

### 4. Add repository secrets

**Settings → Secrets and variables → Actions → New repository secret.** Paste each value. The full reference (every secret + which workflow uses it) is in [docs/operations.md → GitHub Secrets](docs/operations.md#github-secrets). Minimum:

| Category | Secrets |
|---|---|
| vCenter connection | `VSPHERE_SERVER`, `VSPHERE_USER`, `VSPHERE_PASSWORD`, `VSPHERE_DATACENTER`, `VSPHERE_CLUSTER` (or `VSPHERE_HOST`), `VSPHERE_DATASTORE`, `VSPHERE_NETWORK`, `VSPHERE_FOLDER`, `VSPHERE_ISO_LIBRARY_DATASTORE` |
| Build credentials | `BUILD_USERNAME`, `BUILD_PASSWORD`, `BUILD_PASSWORD_ENCRYPTED` |

For `BUILD_PASSWORD_ENCRYPTED` you need a SHA-512 hash. Generate it on the runner VM (or any Linux shell — Codespace, WSL, an existing server):

```bash
openssl passwd -6 'YourBuildPassword'
```

Paste the `$6$…` output into the secret value field.

### 5. Add repository variables (optional)

**Settings → Secrets and variables → Actions → Variables tab:**

| Variable | Default | Purpose |
|---|---|---|
| `CONTENT_LIBRARY` | `Packer-ISOs` | Content Library name |
| `RUNNER_LABEL` | `self-hosted` | Override if you registered the runner with a custom label |
| `TEMPLATE_RETENTION_COUNT` | `2` | Templates kept per `(version, role)` after prune |
| `TEMPLATE_PRUNE_DRY_RUN` | `false` | Set `true` to preview destroy plans before the first real prune |

### 6. Seed the Content Library with ISOs

**Actions → Upload ISOs to Content Library → Run workflow.** Default `ubuntu_versions` is `2204 2404 2604`. Takes roughly 10–20 minutes per ISO depending on bandwidth. The workflow creates the Content Library if it doesn't exist, downloads each ISO with SHA256 verification, and imports it.

### 7. Trigger your first build

**Actions → Build Packer Templates → Run workflow.** Pick `2404-server` (or any single target) for a quick first smoke. Expect roughly 25 minutes wall-clock for a server build, plus another 5 for the post-publish smoke test.

After this initial setup the pipeline runs itself:

| When | What |
|---|---|
| Sundays 02:00 UTC | Rebuild every template, picking up the latest security patches |
| Mondays 06:00 UTC | Check Ubuntu for new ISO point releases; open a bump PR + dispatch the upload if drift is found |
| 1st of each month 03:00 UTC | Prune old templates per the retention policy |
| Every PR | `packer fmt` + `packer validate` + pre-commit hooks |
| Every successful build | Goss smoke test against a freshly-cloned template |

---

## ISO upload in detail

Triggered from **Actions → Upload ISOs to Content Library → Run workflow**. The workflow shells out to `scripts/upload-isos.sh` on the self-hosted runner, which downloads each ISO from `releases.ubuntu.com` with SHA256 verification and imports it via `govc`. Idempotent — already-present ISOs are skipped, so it's safe to re-run after a partial failure. Also dispatched automatically by `check-iso-updates.yml` when Ubuntu publishes a new point release.

**Workflow inputs (`workflow_dispatch`):**

| Input | Default | Description |
|---|---|---|
| `ubuntu_versions` | `2204 2404 2604` | Space-separated versions to process |
| `content_library` | `Packer-ISOs` | Content Library name to create or reuse |
| `download_dir` | `/var/tmp/packer-isos` | Runner-side directory for ISO downloads |
| `keep_downloads` | `false` | `true` keeps the local copy after upload (useful when uploading to multiple vCenters) |
| `skip_checksum` | `false` | `true` skips SHA256 verification (not recommended) |

vCenter credentials and the Content Library backing datastore come from the GitHub Secrets you set during deploy (`VSPHERE_SERVER`, `VSPHERE_USER`, `VSPHERE_PASSWORD`, `VSPHERE_DATACENTER`, `VSPHERE_ISO_LIBRARY_DATASTORE`).

### ISO sources

| Version | ISO | Checksum |
|---|---|---|
| 22.04 LTS | [ubuntu-22.04.5-live-server-amd64.iso](https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso) | [SHA256SUMS](https://releases.ubuntu.com/22.04/SHA256SUMS) |
| 24.04 LTS | [ubuntu-24.04.4-live-server-amd64.iso](https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso) | [SHA256SUMS](https://releases.ubuntu.com/24.04/SHA256SUMS) |
| 26.04 LTS | [ubuntu-26.04-live-server-amd64.iso](https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso) | [SHA256SUMS](https://releases.ubuntu.com/26.04/SHA256SUMS) |

> **Point releases are auto-detected.** The [`check-iso-updates`](.github/workflows/check-iso-updates.yml) workflow runs every Monday and opens a PR rewriting these filenames across the repo when Ubuntu ships a new `.X` release (e.g. `26.04` → `26.04.1`). You shouldn't need to bump them by hand.

All builds use the **live-server ISO** for both server and desktop images. The desktop environment (`ubuntu-desktop-minimal`) is installed by the `desktop.sh` provisioner after the OS install completes — there is no separate desktop ISO to manage.

---

## Variable reference

All variables are declared in `variables.pkr.hcl`. Connection details and credentials are supplied via GitHub Secrets at workflow runtime (see [docs/operations.md → GitHub Secrets](docs/operations.md#github-secrets) for the secret-to-variable mapping). Anything not covered by a secret — typically the hardware sizing defaults below — is overridden by editing the default in `variables.pkr.hcl` directly (via the GitHub web editor or a PR).

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
| `server_2604_ram_mb` | `6144` | RAM in MB (26.04 server only — see note) |
| `server_disk_gb` | `40` | OS disk size in GB |

> **26.04 server RAM**: the 26.04 boot_command appends `toram` — casper copies the entire ~2.8 GB live ISO into RAM at boot, then mounts root from there. At 4 GB the install hits OOM or casper silently falls back to non-toram (mitigation lost); 6 GB leaves ~3 GB headroom for kernel + subiquity + curtin working set + file caches. 22.04 / 24.04 don't use `toram` and stay at 4 GB.

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

### OS configuration

Threaded into the autoinstall user-data at render time, so they apply to every clone of the produced template. Defaults match Ubuntu's own installer defaults; override per-build by editing [`variables.pkr.hcl`](variables.pkr.hcl).

| Variable | Default | Description |
|---|---|---|
| `locale` | `en_GB.UTF-8` | System locale (LANG / LC_*). Examples: `en_US.UTF-8`, `de_DE.UTF-8`, `fr_FR.UTF-8`. Must be a locale Ubuntu's autoinstall accepts — check `locale -a` on any Ubuntu host for valid values. |
| `keyboard_layout` | `gb` | Keyboard layout code mapped to subiquity's `keyboard.layout`. Examples: `us`, `de`, `fr`, `es`. See `localectl list-keymaps` for valid values. |
| `timezone` | `Europe/London` | IANA timezone name, e.g. `America/New_York`, `Asia/Tokyo`. Sets `/etc/localtime` and `/etc/timezone` in the installed OS. |

### ISO paths

| Variable | Default | Description |
|---|---|---|
| `ubuntu_2204_iso_path` | `ISOs/ubuntu-22.04.5-live-server-amd64.iso` | Path within the datastore, or filename if using a Content Library |
| `ubuntu_2404_iso_path` | `ISOs/ubuntu-24.04.4-live-server-amd64.iso` | As above for 24.04 |
| `ubuntu_2604_iso_path` | `ISOs/ubuntu-26.04-live-server-amd64.iso` | As above for 26.04 |

**Datastore vs Content Library:** the `vsphere_iso_datastore` variable accepts either a datastore name or a Content Library name — the vSphere bracket notation `[name]` works identically for both. When pointing at a Content Library, the ISO path should be just the filename with no subfolder prefix.

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
- `source.id: ubuntu-server-minimal` — selects curtin's `fsimage` install source (single-layer mount + tar/cp copy) rather than the default `fsimage-layered` (mount + overlay + copy). On Ubuntu 26.04 the layered handler trips a kernel oops in `ovl_iterate_merged` during the curtin cmd-extract stage ([LP #2150586](https://bugs.launchpad.net/subiquity/+bug/2150586) and friends). The minimal source avoids the overlay code path entirely. 22.04 / 24.04 don't hit the bug but use the same source for consistency.
- `packages: [open-vm-tools]` — installed by subiquity from the network repo into the target rootfs at the in-target apt stage. The minimal squashfs doesn't include open-vm-tools by default, so without this the cloned VM would never report an IP to vSphere.
- LVM storage layout on the first available disk
- SSH server enabled (`allow-pw: true`) so Packer can connect
- Passwordless sudo granted to the build user for provisioner scripts
- `datasource_list: [None]` written to `/etc/cloud/cloud.cfg.d/99-packer.cfg` — neutralises cloud-init on cloned VMs without disabling its systemd units (the older `cloud-init.disabled` approach broke 24.04 networking because cloud-init's boot units are in the dependency chain)
- UFW disabled and the unit masked to `/dev/null` so the firewall does not block SSH on first boot of clones

`snaps: []` is explicitly empty — every snap that needs `systemctl` or D-Bus during install would deadlock inside subiquity's headless chroot on 26.04, so any post-install snap work happens via shell provisioners below.

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
- Rewrites `/etc/netplan/{50-cloud-init,00-installer-config}.yaml` to use `renderer: NetworkManager` + `match: name: "en*"`. Without this, netplan + NM bake the install-time MAC into the rendered NM keyfile, and cloned VMs with a fresh MAC find no matching profile (device stays "unmanaged", no DHCP, no SSH). Matching by interface name pattern is hardware-version-stable on VMware so the keyfile survives the MAC regeneration on clone.

**`vmtools.sh`** — runs last (every variant):
- Verifies `open-vm-tools` is running (the package itself is installed by autoinstall's `packages: [open-vm-tools]` directive)
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

Edit the defaults in [`variables.pkr.hcl`](variables.pkr.hcl) directly — via the GitHub web editor (pencil icon → commit) or a PR. The `build-templates` workflow uses these defaults as-is; there is no separate hardware overrides file.

```hcl
variable "server_cpu_count" {
  default = 4
}
variable "server_ram_mb" {
  default = 4096
}
variable "server_disk_gb" {
  default = 80
}
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

The full operator reference — self-hosted runner setup, per-workflow detail, required vSphere + GitHub Actions permissions, build lifecycle (smoke + retention), and troubleshooting — lives in **[docs/operations.md](docs/operations.md)**.

Key anchors:

- [Setting up the runner](docs/operations.md#setting-up-the-runner) — pre-install commands for zero-sudo operation
- [Required vSphere privileges](docs/operations.md#vsphere) and [GitHub Actions permissions](docs/operations.md#github-actions)
- [GitHub Secrets reference](docs/operations.md#github-secrets) — every secret + which workflow uses it
- [Workflow: build-templates](docs/operations.md#workflow-build-templates) and [Post-publish smoke test](docs/operations.md#post-publish-smoke-test)
- [Template lifecycle](docs/operations.md#template-lifecycle) — retention policy + the standalone rotation workflow
- [Troubleshooting](docs/operations.md#troubleshooting)

---

## Security notes

- Credentials live in GitHub Secrets, never in the repo. `.gitignore` covers `*.pkrvars.hcl` as a belt-and-braces guard in case anyone ever creates a local vars file for ad-hoc testing.
- The build user gets passwordless sudo and SSH password auth during the build (needed for Packer's provisioners). `scripts/finalize.sh` runs as the last provisioner and removes both — `/etc/sudoers.d/90-packer-${build_username}` and `/etc/ssh/sshd_config.d/10-packer-pwauth.conf` — before Packer converts the VM to a template. Clones therefore require pubkey SSH and password-prompted sudo, matching Ubuntu 22.04+ defaults. The goss specs assert both files are absent post-finalize so a regression here would fail the build.
- SSH host keys are wiped by `setup.sh` and regenerated on the first boot of each cloned VM by a oneshot systemd unit (`ssh-host-keygen.service`) that runs before `ssh.socket` and `ssh.service`, then disables itself. This works around the fact that 22.04+ socket-activated SSH never triggers the stock `ssh-keygen@.service`.
- Cloud-init is neutralised on cloned VMs via `/etc/cloud/cloud.cfg.d/99-packer.cfg` containing `datasource_list: [None]` (a no-op datasource). Cloud-init's systemd units still run but do nothing — they are intentionally **not** disabled because cloud-init's boot units are in the dependency chain on 24.04 and disabling them breaks networking. To re-enable cloud-init in your deployment workflow, remove that file.

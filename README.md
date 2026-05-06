# Packer — vSphere Templates

Automated golden-image pipeline that builds Ubuntu and Windows VM templates directly in vSphere using [HashiCorp Packer](https://www.packer.io/). Supports three Ubuntu LTS versions (22.04, 24.04, 26.04) with server and desktop variants, plus Windows Server 2022, Windows Server 2025, and Windows 10 — nine templates in total.

---

## How it works

```
Upload ISOs ──► packer init ──► packer build ──► vSphere Template
(upload-isos.sh)                (vsphere-iso)    (ready to clone)
```

1. **ISO upload** — `scripts/upload-isos.sh` downloads Ubuntu ISOs from `releases.ubuntu.com`, verifies their SHA256 checksums, and imports them into a vSphere Content Library. Windows ISOs are not auto-downloaded (Microsoft requires accepting a EULA on session-bound URLs); upload them manually from the Microsoft Evaluation Center, then run `CHECK_WINDOWS=true scripts/upload-isos.sh` to confirm presence.
2. **Packer build** — the `vsphere-iso` builder boots a VM from the ISO and attaches a secondary CD (labelled `cidata`) carrying the autoinstall configuration. For Ubuntu the CD holds cloud-init `user-data`; for Windows it holds `Autounattend.xml` plus a `bootstrap.ps1` that enables WinRM at first logon.
3. **Provisioning** — shell provisioners run `setup.sh` / `vmtools.sh` on Ubuntu; PowerShell provisioners run `install-vmtools.ps1`, `configure.ps1` on Windows. Windows builds finish with `sysprep.ps1` (`/generalize /oobe /shutdown`).
4. **Template conversion** — the finished VM is converted to a vSphere template in-place.

Autoinstall and autounattend configuration are rendered at build time via HCL's `templatefile()` function, so credentials are injected from your variables file rather than baked into static files.

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| [Packer](https://developer.hashicorp.com/packer/install) | 1.10.0 | `brew install packer` or download binary |
| [govc](https://github.com/vmware/govmomi/releases) | any recent | Required for ISO upload only |
| curl | any | ISO download |
| sha256sum / shasum | any | Checksum verification (pre-installed on Linux/macOS) |
| vCenter | 7.0+ | ESXi standalone also works with minor config changes |

The machine running Packer must be able to reach the vCenter API (port 443), the VM's SSH port (22) for Ubuntu builds, and WinRM port 5985 for Windows builds on the VM network during the build.

---

## Project structure

```
packer/
├── packer.pkr.hcl                  # Plugin requirements (vsphere ≥ 1.3.0)
├── variables.pkr.hcl               # All variable declarations with descriptions
├── locals.pkr.hcl                  # Shared locals: build_date, build_timestamp
│
├── ubuntu-2204.pkr.hcl             # 22.04 server + desktop sources and builds
├── ubuntu-2404.pkr.hcl             # 24.04 server + desktop sources and builds
├── ubuntu-2604.pkr.hcl             # 26.04 server + desktop sources and builds
├── windows-server-2022.pkr.hcl     # Windows Server 2022 source and build
├── windows-server-2025.pkr.hcl     # Windows Server 2025 source and build
├── windows-10.pkr.hcl              # Windows 10 source and build
│
├── templates/
│   ├── server-user-data.pkrtpl              # Cloud-init autoinstall — Ubuntu server
│   ├── desktop-user-data.pkrtpl             # Cloud-init autoinstall — Ubuntu desktop
│   ├── windows-server-autounattend.pkrtpl   # Autounattend.xml — Server 2022 / 2025
│   └── windows-10-autounattend.pkrtpl       # Autounattend.xml — Windows 10
│
├── scripts/
│   ├── upload-isos.sh              # Download Ubuntu ISOs, check Windows ISOs in library
│   ├── setup.sh                    # Ubuntu: apt upgrade, SSH hardening
│   ├── vmtools.sh                  # Ubuntu: verify open-vm-tools
│   ├── desktop.sh                  # Ubuntu desktop-only: ubuntu-desktop-minimal install
│   └── windows/
│       ├── bootstrap.ps1           # Runs at first logon — enables WinRM for Packer
│       ├── install-vmtools.ps1     # Silent install of VMware Tools from mounted ISO
│       ├── configure.ps1           # Cleanup, telemetry off, lean-template tweaks
│       └── sysprep.ps1             # /generalize /oobe /shutdown — last provisioner
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
| `DOWNLOAD_DIR` | no | `/tmp/packer-isos` | Local directory for ISO downloads |
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

All builds use the **live-server ISO** for both server and desktop images. The desktop environment (`ubuntu-desktop-minimal`) is installed via the autoinstall package list — there is no separate desktop ISO to manage.

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
| `vsphere_folder` | no | `"Templates"` | VM folder path for finished templates |
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
| `server_ram_mb` | `2048` | RAM in MB |
| `server_disk_gb` | `40` | OS disk size in GB |

### VM hardware — desktop

| Variable | Default | Description |
|---|---|---|
| `desktop_cpu_count` | `4` | vCPU cores |
| `desktop_ram_mb` | `4096` | RAM in MB |
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

## Windows builds

Windows differs from Ubuntu in three places that matter:

1. **ISOs are not auto-downloaded.** Microsoft's Eval Center URLs are session-bound and require accepting a EULA. Download manually and import:
   ```bash
   govc library.import Packer-ISOs /path/to/SERVER_EVAL_x64FRE_en-us.iso
   ```
   Then run `CHECK_WINDOWS=true scripts/upload-isos.sh` to confirm presence.
2. **The communicator is WinRM, not SSH.** Port 5985 must be reachable from the runner. The autounattend's `FirstLogonCommands` runs `bootstrap.ps1` from the secondary CD which enables WinRM HTTP for the build window.
3. **No activation keys required.** Each `windows-*.pkr.hcl` hardcodes the [public KMS Client Setup Key](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys) for its default edition. These do not activate Windows — they only suppress the install-time product-key prompt. The OS lands unactivated (Eval ISOs grant 90-180 days; otherwise unlicensed).

### Windows variables

| Variable | Default | Description |
|---|---|---|
| `windows_server_2022_iso_path` | `ISOs/SERVER_EVAL_x64FRE_en-us.iso` | Path to the Server 2022 ISO |
| `windows_server_2025_iso_path` | `ISOs/SERVER_2025_EVAL_x64FRE_en-us.iso` | Path to the Server 2025 ISO |
| `windows_10_iso_path` | `ISOs/Win10_22H2_EnglishInternational_x64.iso` | Path to the Windows 10 ISO |
| `windows_server_2022_image_name` | `Windows Server 2022 SERVERSTANDARD` | Image name (`/IMAGE/NAME`) inside the ISO |
| `windows_server_2025_image_name` | `Windows Server 2025 SERVERSTANDARD` | As above for 2025 |
| `windows_10_image_name` | `Windows 10 Enterprise Evaluation` | As above for Win 10 |
| `windows_admin_password` | — | Built-in Administrator password (sensitive). Required for any Windows build |
| `windows_timezone` | `GMT Standard Time` | Windows timezone (`tzutil /l` for the full list) |
| `windows_server_cpu_count` / `_ram_mb` / `_disk_gb` | `2` / `4096` / `60` | Server hardware sizing |
| `windows_desktop_cpu_count` / `_ram_mb` / `_disk_gb` | `2` / `4096` / `60` | Win 10 hardware sizing |

### Switching editions

To build Datacenter instead of Standard, override both the image name and the product key. The product key local lives at the top of each `windows-server-*.pkr.hcl` — change it to the matching KMS Client Setup Key. Image names are listed by `Get-WindowsImage -ImagePath D:\sources\install.wim` on a Windows host.

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
make build-all       # All Ubuntu + Windows images (sequential)

make windows-server-2022   # Windows Server 2022
make windows-server-2025   # Windows Server 2025
make windows-10            # Windows 10
make windows               # All three Windows images
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
| RAM | 2 GB |
| Disk | 40 GB thin-provisioned (LVM) |
| Network | vmxnet3, DHCP |
| Firmware | EFI Secure Boot |
| Extra packages | open-vm-tools, curl, wget, vim, git, net-tools |

### Desktop images

| Setting | Value |
|---|---|
| OS | Ubuntu Desktop (ubuntu-desktop-minimal + GNOME) |
| vCPUs | 4 (1 socket × 4 cores) |
| RAM | 4 GB |
| Disk | 60 GB thin-provisioned (LVM) |
| Network | vmxnet3, DHCP |
| Firmware | EFI Secure Boot |
| Extra packages | open-vm-tools, open-vm-tools-desktop, curl, wget, vim, git |

All sizes are configurable via variables.

---

## What gets installed

### OS install (autoinstall / cloud-init)

The autoinstall seed is written to a small ISO (labelled `cidata`) at build time via Packer's `cd_content` mechanism. No HTTP server is required — vSphere mounts the seed disc directly. The installer runs fully unattended and powers off the VM when complete.

Key autoinstall steps:
- LVM storage layout on the first available disk
- SSH server enabled (`allow-pw: true`) so Packer can connect
- `open-vm-tools` (and `open-vm-tools-desktop` for desktop builds) installed
- Passwordless sudo granted to the build user for provisioner scripts
- `cloud-init.disabled` created so cloud-init does not run again on cloned VMs

### Shell provisioners (`scripts/`)

**`setup.sh`** — runs after the OS install completes:
- `apt-get update && apt-get upgrade` (full security upgrade)
- Installs common utilities
- Disables swap and tunes `vm.swappiness`
- Removes SSH host keys (regenerated on first boot of each clone)
- Appends SSH hardening config (`PermitRootLogin no`, etc.)
- Zeroes free disk space for smaller template storage footprint

**`vmtools.sh`** — verifies open-vm-tools:
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

Edit the network section in the relevant `templates/*-user-data.pkrtpl`:

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

## GitHub Actions CI/CD

Three workflows cover the full pipeline. Almost everything runs from Actions — the only local step is the one-time `make secrets` to populate credentials (you can't set GitHub secrets from within Actions itself without a Personal Access Token).

```
Local (one-time)                GitHub Actions (ongoing, automated)
────────────────                ───────────────────────────────────────────
1. Fill in pkrvars file
2. make secrets              ─► secrets stored in GitHub

                                PR opened
                                └─► validate.yml
                                    fmt check + packer validate
                                    (ubuntu-latest, no secrets needed)

                                Merge to main / manual trigger / weekly cron
                                └─► build-templates.yml
                                    packer build → vSphere template
                                    (self-hosted runner)

3. Trigger upload-isos.yml   ─► upload-isos.yml
   from Actions UI               govc library.import → Content Library
   (or: make upload-isos          (self-hosted runner, manual only)
    if runner has govc locally)
```

> **Steps 1–3 are one-time setup.** After that, builds run automatically on push to `main`, on a weekly schedule, or on demand from the Actions UI. No local tooling is needed day-to-day.

### Why a self-hosted runner

GitHub-hosted runners live on the public internet and cannot reach a private vCenter. A **self-hosted runner** installed on a machine inside your vSphere network solves this — it dials out to GitHub (port 443) to pick up jobs, so no inbound firewall rules are needed.

The runner machine needs:
- Outbound HTTPS to `github.com` and `*.actions.githubusercontent.com`
- Access to the vCenter API (port 443)
- Access to the VM network on port 22 (so Packer can SSH into the VM during the build)
- `curl`, `git`, and enough disk space to cache the Packer plugin (~50 MB)

A small Ubuntu VM on the same network as vCenter works well. The runner can be registered to a repository, organisation, or enterprise.

### Setting up the runner

1. In your GitHub repository go to **Settings → Actions → Runners → New self-hosted runner**
2. Follow the on-screen instructions to download and register the runner agent on your machine
3. Start the runner as a service so it survives reboots:

```bash
sudo ./svc.sh install
sudo ./svc.sh start
```

4. The runner user needs passwordless sudo so Packer can install dependencies:

```bash
echo "YOUR_RUNNER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/github-runner
```

By default the workflows target any runner registered with the default `self-hosted` label (`runs-on: self-hosted`). To target a specific runner or label, set the **`RUNNER_LABEL`** repository variable:

**Settings → Secrets and variables → Actions → Variables → New repository variable**

| Variable | Example value | Effect |
|---|---|---|
| `RUNNER_LABEL` | `vsphere` | Targets runners with that label instead of `self-hosted` |

If `RUNNER_LABEL` is not set, the workflows fall back to `self-hosted`.

### GitHub Secrets

The easiest way to populate secrets is with the included sync script, which reads your local `variables.pkrvars.hcl` and pushes every value to GitHub in one step:

```bash
# Authenticate the GitHub CLI (one-time)
gh auth login

# Push all secrets from your local vars file
make secrets

# Preview what would be pushed without actually setting anything
DRY_RUN=true make secrets

# Target a specific repo (if auto-detection fails)
GH_REPO=owner/repo make secrets
```

The script (`scripts/set-github-secrets.sh`) detects the repository from your `git remote origin` automatically, so there's nothing to configure. Re-run it any time you change a value in `variables.pkrvars.hcl` — existing secrets are overwritten in place.

To set secrets manually instead, go to **Settings → Secrets and variables → Actions → New repository secret** and create each one from the table below.

| Secret | Source variable | Description |
|---|---|---|
| `VSPHERE_SERVER` | `vsphere_server` | vCenter URL, e.g. `https://vcenter.example.com` |
| `VSPHERE_USER` | `vsphere_user` | vCenter username |
| `VSPHERE_PASSWORD` | `vsphere_password` | vCenter password |
| `VSPHERE_INSECURE` | `vsphere_insecure_connection` | `true` to skip TLS verification |
| `VSPHERE_DATACENTER` | `vsphere_datacenter` | Datacenter name |
| `VSPHERE_CLUSTER` | `vsphere_cluster` | Cluster name (blank if using `VSPHERE_HOST`) |
| `VSPHERE_HOST` | `vsphere_host` | ESXi host (blank if using `VSPHERE_CLUSTER`) |
| `VSPHERE_DATASTORE` | `vsphere_datastore` | Datastore for VM storage |
| `VSPHERE_NETWORK` | `vsphere_network` | Port group / network name |
| `VSPHERE_FOLDER` | `vsphere_folder` | VM folder for finished templates |
| `VSPHERE_ISO_DATASTORE` | `vsphere_iso_datastore` | Datastore or Content Library name holding ISOs |
| `VSPHERE_ISO_LIBRARY_DATASTORE` | `vsphere_iso_library_datastore` | Datastore backing the Content Library (upload workflow). Defaults to `vsphere_datastore` if unset. |
| `BUILD_USERNAME` | `build_username` | OS user created during install |
| `BUILD_PASSWORD` | `build_password` | Plaintext build password |
| `BUILD_PASSWORD_ENCRYPTED` | `build_password_encrypted` | SHA-512 hash — `openssl passwd -6 '<password>'` |
| `UBUNTU_2204_ISO_PATH` | `ubuntu_2204_iso_path` | ISO filename/path for 22.04 |
| `UBUNTU_2404_ISO_PATH` | `ubuntu_2404_iso_path` | ISO filename/path for 24.04 |
| `UBUNTU_2604_ISO_PATH` | `ubuntu_2604_iso_path` | ISO filename/path for 26.04 |

### Workflow: validate

**File:** `.github/workflows/validate.yml`

**Triggers:** Every pull request that touches `.pkr.hcl` files, templates, or provisioner scripts. Also runs on push to `main` and can be triggered manually.

**Runner:** `ubuntu-latest` — this is a GitHub-hosted runner. No self-hosted runner or real secrets are needed because `packer validate` checks syntax and variable references only; it never contacts vSphere. Placeholder values are passed for required variables.

**What it does:**

1. Installs Packer and downloads the vsphere plugin (`packer init`)
2. Runs `packer fmt --check` — fails the PR if any file needs reformatting (fix with `packer fmt .` locally)
3. Runs `packer validate` against all six builds — catches undefined variables, bad HCL, and broken `templatefile()` references before anything reaches main

This gives fast feedback (typically under 2 minutes) on every PR with no infrastructure cost.

### Workflow: build-templates

**File:** `.github/workflows/build-templates.yml`

**Triggers:**

- **Manual** (`workflow_dispatch`) — choose a specific template or `all`, with an optional dry-run (validate only) toggle
- **Push to `main`** — automatically rebuilds when any `.pkr.hcl` file, template, or provisioner script changes
- **Schedule** — rebuilds all templates every Sunday at 02:00 UTC, picking up the latest security updates

**What it does:**

1. Resolves which builds to run into a matrix based on the trigger/input
2. Each matrix entry runs in parallel on the self-hosted runner (up to vSphere resource limits)
3. **Pre-flight secrets check** — fails immediately with a clear list of any missing secrets before any tools are installed
4. Installs Packer via direct binary download (codename-independent — works on any Ubuntu release), runs `packer init`, then `packer validate`
5. Runs `packer build` with `PACKER_LOG=1` for full debug output
6. Uploads the Packer log and build manifest as workflow artifacts
7. Always deletes the temporary credentials file, even on failure

**Running manually:**

Go to **Actions → Build Packer Templates → Run workflow**, pick a target, and optionally enable dry-run to validate without building.

```
workflow_dispatch inputs:
  build_target → 2404-server | 2404-desktop | all-servers | all | …
  dry_run      → false (default) | true
```

### Workflow: upload-isos

**File:** `.github/workflows/upload-isos.yml`

**Trigger:** Manual only — run this once during initial setup or whenever Ubuntu releases a new point version.

**What it does:** Runs `scripts/upload-isos.sh` on the self-hosted runner, downloading ISOs from `releases.ubuntu.com` and importing them into your vSphere Content Library via govc. Installs govc automatically if not present on the runner.

```
workflow_dispatch inputs:
  ubuntu_versions  → "2204 2404 2604" (default) or any subset
  content_library  → "Packer-ISOs" (default)
  keep_downloads   → false | true
  skip_checksum    → false | true
```

### Concurrency

The build workflow uses a `concurrency` group (`packer-build`) so that only one build pipeline runs at a time — preventing two jobs from racing to create VMs with the same name in vSphere. A queued run waits for the current one to finish rather than being cancelled.

---

## Troubleshooting

**`Error: No builds to run` with `-only` flag**
Packer's full source reference format is `<build-label>.<source-type>.<source-name>` (e.g. `ubuntu-2404-server.vsphere-iso.ubuntu-2404-server`). Passing just `vsphere-iso.ubuntu-2404-server` does not match. Use a glob: `-only='*.vsphere-iso.ubuntu-2404-server'`. The Makefile and workflows already use this format.

**`vcenter_server is required` / `ssh_username must be specified` errors**
The build workflow pre-flight check will list exactly which secrets are absent before Packer runs. Go to **Settings → Secrets and variables → Actions** and add any missing secrets, or re-run `make secrets` after updating `variables.pkrvars.hcl`.

**Runner not picking up jobs**
Check the label the runner was registered with (visible in **Settings → Actions → Runners**). If it does not match `self-hosted`, set the `RUNNER_LABEL` repository variable to the correct label. See [Setting up the runner](#setting-up-the-runner).

**Runner sudo prompt blocks job**
The runner user must have passwordless sudo. Add the sudoers entry described in [Setting up the runner](#setting-up-the-runner) and re-trigger the workflow.

**Build hangs at `Waiting for SSH`**
The VM booted but Packer cannot reach port 22. Check that the machine running Packer has network access to the VM's subnet. Temporarily set `PACKER_LOG=1` and watch the boot sequence via the vSphere console.

**`autoinstall` not triggering / VM boots to live shell**
The boot command uses GRUB's command line (`c`) to inject kernel parameters. If the GRUB menu layout changes between Ubuntu point releases the timing or keystrokes may need adjusting. Increase `boot_wait` in the source block (e.g. `"10s"`) and check the GRUB prompt appears before characters are typed.

**Checksum mismatch on ISO download**
Ubuntu occasionally re-releases point ISOs with updated checksums. Re-run the upload script — it will re-download and replace the file. If the ISO filename has changed (e.g. `22.04.5`), update `ISO_FILENAME[2204]` in `scripts/upload-isos.sh` and the `ubuntu_2204_iso_path` variable.

**`govc library.import` fails**
Ensure the datastore has enough free space for the ISO (typically 1–2 GB each). Check that the vCenter user has the `Content library > Add library item` privilege.

**`disk_size` errors**
Disk size is specified in MB internally (`var.server_disk_gb * 1024`). If you see validation errors, confirm your `server_disk_gb` / `desktop_disk_gb` values are plain integers with no units.

**Desktop build times out on SSH**
Installing `ubuntu-desktop-minimal` takes significantly longer than a server install. The desktop source blocks use a 90-minute SSH timeout. If your environment is slow, increase `ssh_timeout` in the relevant source block.

---

## Security notes

- `variables.pkrvars.hcl` contains credentials — never commit it. The `.gitignore` entry is set up in the quick start.
- The build user is granted passwordless sudo during the build. `setup.sh` does **not** remove this — if you want to lock it down in the final template, add a `late-commands` step or a provisioner that removes `/etc/sudoers.d/90-packer-ubuntu`.
- SSH host keys are wiped by `setup.sh` and regenerated on the first boot of each cloned VM via `/etc/rc.local`.
- `cloud-init.disabled` prevents cloud-init from resetting the hostname or reconfiguring the network on clone. Remove this file if your deployment workflow relies on cloud-init.

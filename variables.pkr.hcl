# =============================================================================
# vSphere Connection
# =============================================================================

variable "vsphere_server" {
  type        = string
  description = "vCenter Server hostname or IP address (e.g. vcenter.example.com)"
}

variable "vsphere_user" {
  type        = string
  description = "vCenter username (e.g. administrator@vsphere.local)"
}

variable "vsphere_password" {
  type        = string
  description = "vCenter password"
  sensitive   = true
}

variable "vsphere_insecure_connection" {
  type        = bool
  description = "Skip TLS certificate verification — set to false in production"
  default     = false
}

# =============================================================================
# vSphere Infrastructure
# =============================================================================

variable "vsphere_datacenter" {
  type        = string
  description = "Name of the vSphere datacenter"
}

variable "vsphere_cluster" {
  type        = string
  description = "Name of the vSphere cluster (leave empty to use vsphere_host directly)"
  default     = ""
  # Note: "exactly one of vsphere_cluster / vsphere_host" cannot be enforced
  # here — Packer variable validation blocks may only reference their own
  # variable, not vsphere_host. The locals ternary in each ubuntu-*.pkr.hcl
  # turns "" into null and lets the builder pick whichever is set; if both are
  # empty the build fails fast at clone with a placement error.
}

variable "vsphere_host" {
  type        = string
  description = "Specific ESXi host for placement (required if vsphere_cluster is empty)"
  default     = ""
}

variable "vsphere_datastore" {
  type        = string
  description = "Datastore for VM storage"
}

variable "vsphere_network" {
  type        = string
  description = "Port group / network name to attach to the VM NIC"
}

variable "vsphere_folder" {
  type        = string
  description = "VM inventory folder path for finished templates"
  default     = "packer"
}

variable "git_commit" {
  type        = string
  description = "Short git commit SHA stamped into the VM notes field. Set automatically by the GitHub Actions workflow via GITHUB_SHA. Defaults to 'unknown' for local builds."
  default     = "unknown"
}

variable "vsphere_iso_datastore" {
  type        = string
  description = "Datastore OR Content Library name that holds the Ubuntu ISO files. The builder uses the vSphere bracket notation [name] for both — just set this to the datastore or content library name without brackets."
}

# =============================================================================
# Template Publishing (optional)
# =============================================================================

variable "vsphere_template_content_library" {
  type        = string
  description = "Local-type Content Library to publish finished templates into, as updatable OVF items. Defaults to 'Packer-ISOs' — the same library the ISOs live in — so templates and source ISOs sit together. Set to a different library name to publish elsewhere, or to an empty string to disable publishing (inventory VM templates are still produced). The library must already exist. Each source publishes under a stable name (e.g. ubuntu-2404-server) so repeat builds update the same item (always-latest), while the dated inventory template is what rotate/prune manage."
  default     = "Packer-ISOs"
}

# =============================================================================
# Build Credentials
# =============================================================================

variable "build_username" {
  type        = string
  description = "Admin username created during the OS install"
  default     = "ubuntu"

  # Guard the "unset secret clobbers the default" footgun: CI feeds this from a
  # secret with no per-var fallback, so a missing BUILD_USERNAME would pass
  # build_username = "" — silently overriding the "ubuntu" default. An empty
  # username makes autoinstall create a nameless user, writes a "'' ALL=..."
  # sudoers entry, and leaves Packer trying to SSH as "". Fail at validate
  # instead. (The workflow also defaults to 'ubuntu' as a first line of defence.)
  validation {
    condition     = length(trimspace(var.build_username)) > 0
    error_message = "The build_username must not be empty. In CI, set the BUILD_USERNAME secret (the workflow also falls back to 'ubuntu')."
  }
}

variable "build_password" {
  type        = string
  description = "Plaintext password — used by Packer for the SSH connection during build"
  sensitive   = true
}

variable "build_password_encrypted" {
  type        = string
  description = "SHA-512 hashed password injected into autoinstall user-data. Generate with: openssl passwd -6 '<your-password>'"
  sensitive   = true

  # autoinstall expects a SHA-512 crypt hash ($6$...). A plaintext password or
  # a wrong-algorithm hash here produces an account with an unusable password
  # and no clear error until the build fails at SSH. Catch it at validate.
  validation {
    condition     = can(regex("^\\$6\\$", var.build_password_encrypted))
    error_message = "The build_password_encrypted value must be a SHA-512 crypt hash starting with '$6$'. Generate with: openssl passwd -6 '<password>'."
  }
}

variable "build_ssh_authorized_keys" {
  type        = list(string)
  description = "SSH public keys injected into autoinstall as authorized_keys for build_username. The CI workflow generates a fresh ephemeral keypair per build and passes the pubkey here. For local builds, leave empty — Packer will fall back to ssh_password."
  default     = []
}

variable "build_ssh_private_key_file" {
  type        = string
  description = "Path to the SSH private key Packer should use for the build SSH connection. Set by the CI workflow alongside build_ssh_authorized_keys. For local builds, leave empty — Packer will fall back to ssh_password."
  default     = ""
  sensitive   = true
}

# =============================================================================
# VM Hardware — Server
# =============================================================================

variable "server_cpu_count" {
  type        = number
  description = "Number of vCPUs (cores) for server images"
  default     = 2
}

variable "server_ram_mb" {
  type        = number
  description = "RAM in MB for server images (all versions)."
  default     = 4096
}

variable "server_disk_gb" {
  type        = number
  description = "OS disk size in GB for server images"
  default     = 40
}

# =============================================================================
# VM Hardware — Desktop
# =============================================================================

variable "desktop_cpu_count" {
  type        = number
  description = "Number of vCPUs (cores) for desktop images"
  default     = 4
}

variable "desktop_ram_mb" {
  type        = number
  description = "RAM in MB for desktop images"
  default     = 8192
}

variable "desktop_disk_gb" {
  type        = number
  description = "OS disk size in GB for desktop images"
  default     = 60
}

# =============================================================================
# VM Hardware — General
# =============================================================================

variable "vm_hardware_version" {
  type        = number
  description = "VMware hardware version. 19 = vSphere 7.0 U2, 20 = vSphere 8.0, 21 = vSphere 8.0 U2"
  default     = 21

  # Only the documented, tested hardware versions are supported. A typo (e.g.
  # 12 or 210) would otherwise reach the builder and fail deep in the clone.
  validation {
    condition     = contains([19, 20, 21], var.vm_hardware_version)
    error_message = "The vm_hardware_version must be one of 19 (vSphere 7.0 U2), 20 (vSphere 8.0), or 21 (vSphere 8.0 U2)."
  }
}

# =============================================================================
# Admin User (optional)
# =============================================================================

variable "admin_username" {
  type        = string
  description = "Optional persistent admin account to create in the template (e.g. your personal username). Leave empty to skip. A NOPASSWD sudoers entry is added automatically."
  default     = ""
}

variable "admin_github_user" {
  type        = string
  description = "GitHub username whose public SSH keys are imported for admin_username. Leave empty to skip key import."
  default     = ""
}

# =============================================================================
# OS Configuration
# =============================================================================

variable "timezone" {
  type        = string
  description = "Timezone to configure in the installed OS (e.g. Europe/London, America/New_York)"
  default     = "Europe/London"
}

variable "locale" {
  type        = string
  description = "System locale (LANG / LC_*) — e.g. en_GB.UTF-8, en_US.UTF-8, de_DE.UTF-8. Must be a locale Ubuntu's autoinstall accepts; check `locale -a` on any Ubuntu host for valid values."
  default     = "en_GB.UTF-8"
}

variable "keyboard_layout" {
  type        = string
  description = "Keyboard layout code — e.g. `gb`, `us`, `de`, `fr`. Matches subiquity's `keyboard.layout` field; see `localectl list-keymaps` for valid values."
  default     = "gb"
}

# =============================================================================
# ISO Paths (relative to vsphere_iso_datastore)
# =============================================================================

variable "ubuntu_2204_iso_path" {
  type        = string
  description = "ISO filename/path within the datastore or content library. For a datastore use a folder path (e.g. ISOs/ubuntu-22.04.5-live-server-amd64.iso). For a content library use the filename only (e.g. ubuntu-22.04.5-live-server-amd64.iso)."
  default     = "ISOs/ubuntu-22.04.5-live-server-amd64.iso"
}

variable "ubuntu_2404_iso_path" {
  type        = string
  description = "ISO filename/path within the datastore or content library. For a datastore use a folder path (e.g. ISOs/ubuntu-24.04.4-live-server-amd64.iso). For a content library use the filename only (e.g. ubuntu-24.04.4-live-server-amd64.iso)."
  default     = "ISOs/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "ubuntu_2604_iso_path" {
  type        = string
  description = "ISO filename/path within the datastore or content library. For a datastore use a folder path (e.g. ISOs/ubuntu-26.04-live-server-amd64.iso). For a content library use the filename only (e.g. ubuntu-26.04-live-server-amd64.iso)."
  default     = "ISOs/ubuntu-26.04-live-server-amd64.iso"
}

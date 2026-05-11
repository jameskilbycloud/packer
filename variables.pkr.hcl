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
# Build Credentials
# =============================================================================

variable "build_username" {
  type        = string
  description = "Admin username created during the OS install"
  default     = "ubuntu"
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
  description = "RAM in MB for server images (22.04 / 24.04). 26.04 server overrides via server_2604_ram_mb."
  default     = 4096
}

variable "server_2604_ram_mb" {
  type        = number
  description = "RAM in MB for the 26.04 server image. Higher than 22.04 / 24.04 because subiquity's snap-seeding step on 26.04 hangs intermittently at 4 GB — believed to be a memory-pressure deadlock in the headless chroot. 8 GB has reproduced clean builds where 4 GB hangs at 'Waiting for SSH' for the full ssh_timeout window."
  default     = 8192
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

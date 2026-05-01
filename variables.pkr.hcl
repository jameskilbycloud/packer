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
  default     = "Templates"
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
  description = "RAM in MB for server images"
  default     = 2048
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
  default     = 4096
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

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
# OS Configuration
# =============================================================================

variable "timezone" {
  type        = string
  description = "Timezone to configure in the installed OS (e.g. Europe/London, America/New_York)"
  default     = "Europe/London"
}

variable "windows_timezone" {
  type        = string
  description = "Windows timezone name. Windows uses different IDs to IANA — e.g. 'GMT Standard Time' (London), 'Eastern Standard Time' (NY), 'UTC'. Run `tzutil /l` on a Windows host for the full list."
  default     = "GMT Standard Time"
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

variable "windows_server_2022_iso_path" {
  type        = string
  description = "Windows Server 2022 ISO filename/path within the datastore or content library. ISOs are not auto-downloaded — upload manually (e.g. from the Microsoft Evaluation Center)."
  default     = "ISOs/SERVER_EVAL_x64FRE_en-us.iso"
}

variable "windows_server_2025_iso_path" {
  type        = string
  description = "Windows Server 2025 ISO filename/path within the datastore or content library. ISOs are not auto-downloaded — upload manually (e.g. from the Microsoft Evaluation Center)."
  default     = "ISOs/SERVER_2025_EVAL_x64FRE_en-us.iso"
}

variable "windows_10_iso_path" {
  type        = string
  description = "Windows 10 ISO filename/path within the datastore or content library. ISOs are not auto-downloaded — upload manually (e.g. Win10 Enterprise Evaluation from the Microsoft Evaluation Center)."
  default     = "ISOs/Win10_22H2_EnglishInternational_x64.iso"
}

# =============================================================================
# Windows — image / edition selection
# =============================================================================
# Each ISO contains multiple images selectable by index. Use Get-WindowsImage
# (PowerShell) or the Microsoft Evaluation Center release notes to confirm
# the exact NAME for the edition you want, then set it here. The autounattend
# template uses the Name (more stable than Index across rebuilds).

variable "windows_server_2022_image_name" {
  type        = string
  description = "Image name for Windows Server 2022 (e.g. 'Windows Server 2022 SERVERSTANDARD' for Standard with Desktop Experience, or 'Windows Server 2022 SERVERDATACENTER' for Datacenter)"
  default     = "Windows Server 2022 SERVERSTANDARD"
}

variable "windows_server_2025_image_name" {
  type        = string
  description = "Image name for Windows Server 2025 (e.g. 'Windows Server 2025 SERVERSTANDARD' for Standard with Desktop Experience)"
  default     = "Windows Server 2025 SERVERSTANDARD"
}

variable "windows_10_image_name" {
  type        = string
  description = "Image name for Windows 10 (e.g. 'Windows 10 Enterprise Evaluation', 'Windows 10 Pro')"
  default     = "Windows 10 Enterprise Evaluation"
}

# =============================================================================
# Windows — credentials
# =============================================================================
# Windows uses WinRM rather than SSH during the build. The build always uses
# the built-in Administrator account; the password set here is consumed by
# autounattend.xml at install time and by Packer's WinRM connection thereafter.

variable "windows_admin_password" {
  type        = string
  description = "Plaintext password for the Windows built-in Administrator account. Must satisfy Windows complexity rules (≥ 8 chars, 3 of 4 character classes). Default is empty so `packer validate` succeeds for Linux-only builds — the GitHub Actions workflow enforces a real value for Windows runs."
  sensitive   = true
  default     = ""
}

# =============================================================================
# VM Hardware — Windows
# =============================================================================

variable "windows_server_cpu_count" {
  type        = number
  description = "Number of vCPUs for Windows Server images"
  default     = 2
}

variable "windows_server_ram_mb" {
  type        = number
  description = "RAM in MB for Windows Server images"
  default     = 4096
}

variable "windows_server_disk_gb" {
  type        = number
  description = "OS disk size in GB for Windows Server images"
  default     = 60
}

variable "windows_desktop_cpu_count" {
  type        = number
  description = "Number of vCPUs for Windows Desktop (Win 10) images"
  default     = 2
}

variable "windows_desktop_ram_mb" {
  type        = number
  description = "RAM in MB for Windows Desktop (Win 10) images"
  default     = 4096
}

variable "windows_desktop_disk_gb" {
  type        = number
  description = "OS disk size in GB for Windows Desktop (Win 10) images"
  default     = 60
}

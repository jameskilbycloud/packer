locals {
  # Timestamp used in VM / template names so each build is uniquely identifiable.
  build_date      = formatdate("YYYYMMDD", timestamp())
  build_timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())

  # Convenience: padded shutdown timeout used across all builds.
  shutdown_timeout = "15m"

  # SSH timeouts — server builds are faster; desktop installs take longer due
  # to the ubuntu-desktop-minimal package set. Ubuntu 26.04 desktop can take
  # longer again due to the expanded package/snap footprint.
  # Note: ssh_timeout counts from when Packer first starts attempting connections
  # (after ip_settle_timeout completes), not from build start.
  ssh_timeout              = "90m"
  desktop_ssh_timeout      = "120m"
  desktop_2604_ssh_timeout = "150m"

  # Windows timeouts — WinRM connection retries from the moment the IP is
  # reported by VMware Tools (after autounattend's autologon + bootstrap.ps1
  # have enabled WinRM). Generous to absorb cumulative-update-driven first-boot
  # delays. Shutdown timeout is long because sysprep generalize takes 5-10 min
  # before it actually issues the power-off.
  windows_winrm_timeout    = "120m"
  windows_shutdown_timeout = "30m"
}

locals {
  # Timestamp used in VM / template names so each build is uniquely identifiable.
  build_date      = formatdate("YYYYMMDD", timestamp())
  build_timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())

  # Convenience: padded shutdown timeout used across all builds.
  shutdown_timeout = "15m"

  # SSH timeouts — server builds are faster; desktop installs take longer due
  # to the ubuntu-desktop-minimal package set.
  # Note: ssh_timeout counts from when Packer first starts attempting connections
  # (after ip_settle_timeout completes), not from build start.
  ssh_timeout         = "90m"
  desktop_ssh_timeout = "120m"
}

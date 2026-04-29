locals {
  # Timestamp used in VM / template names so each build is uniquely identifiable.
  build_date      = formatdate("YYYYMMDD", timestamp())
  build_timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())

  # Convenience: padded shutdown timeout used across all builds.
  shutdown_timeout = "15m"

  # SSH timeouts — server builds are faster; desktop installs take longer due
  # to the ubuntu-desktop-minimal package set.
  ssh_timeout         = "45m"
  desktop_ssh_timeout = "90m"
}

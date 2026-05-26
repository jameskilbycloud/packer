locals {
  # Timestamp used in VM / template names so each build is uniquely identifiable.
  build_date      = formatdate("YYYYMMDD", timestamp())
  build_timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())

  # Convenience: padded shutdown timeout used across all builds.
  shutdown_timeout = "15m"

  # SSH timeouts — capped at 90m for fail-fast. A healthy install reaches SSH
  # in 5–15 minutes; anything still waiting at 90m is hung (subiquity
  # _send_update CHANGE loop, kernel oops in image-extract, etc.) and will
  # not recover by waiting longer. Burning 3h on a known-hung VM blocks the
  # runner and delays the diagnostic screenshot, so cap the budget at 90m
  # and let the screenshot step + retry decision logic act sooner.
  # Note: ssh_timeout counts from when Packer first starts attempting connections
  # (after ip_settle_timeout completes), not from build start.
  ssh_timeout              = "90m"
  desktop_ssh_timeout      = "90m"
  server_2604_ssh_timeout  = "90m"
  desktop_2604_ssh_timeout = "90m"

}

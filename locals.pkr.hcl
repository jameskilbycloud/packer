locals {
  # Timestamp used in VM / template names so each build is uniquely identifiable.
  build_date      = formatdate("YYYYMMDD", timestamp())
  build_timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())

  # Convenience: padded shutdown timeout used across all builds.
  shutdown_timeout = "15m"

  # SSH timeouts — capped at 30m for fail-fast. Observed clean builds across
  # 22.04 / 24.04 / 26.04 (server + desktop) finish in ~24-28 min total wall-
  # clock, of which the SSH wait phase is only ~15-20 min. 30m gives ~50%
  # headroom over the slowest clean observation, well outside normal variance,
  # while cutting each stuck attempt's burn by an hour compared to the
  # previous 90m setting.
  #
  # When the 26.04 OverlayFS oops fires (curtin's cmd-extract → rsync killed
  # with irqs disabled, kernel trace in [overlay]), the install is unrecoverable
  # — no point waiting longer. With MAX_ATTEMPTS=2 the total per-template
  # worst-case becomes ~70 min (30m + 60s backoff + 30m) instead of ~3h+,
  # so retries against a probabilistic kernel bug stay tractable.
  #
  # Note: ssh_timeout counts from when Packer first starts attempting
  # connections (after ip_settle_timeout completes), not from build start.
  ssh_timeout         = "30m"
  desktop_ssh_timeout = "30m"

}

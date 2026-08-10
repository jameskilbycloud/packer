packer {
  required_version = ">= 1.14.0"

  required_plugins {
    vsphere = {
      # Pinned to the 2.3.x line, not ">=". Packer has no plugin lockfile and
      # `packer init .` runs on a fresh runner every job, so an open-ended
      # constraint silently adopts each new release the day it ships — this
      # repo moved 2.1.2 → 2.2.0 → 2.3.0 with no commit and no changelog entry.
      # Bump this deliberately, after reading the release notes.
      #
      # 2.3.0 (2026-08-03) is the floor because of #799: before it, a failed
      # artifact cleanup could crash the RPC boundary and surface a panic
      # instead of the real error, which the retry loop in build-templates.yml
      # classifies by grepping the tail of the Packer log.
      version = "~> 2.3.0"
      source  = "github.com/vmware/vsphere"
    }
  }
}

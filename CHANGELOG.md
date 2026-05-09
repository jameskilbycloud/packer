# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Per-clone hostname uniquification via a `firstboot-hostname.service`
  oneshot systemd unit installed by `setup.sh`. Each clone boots with
  `<template-hostname>-<6-hex-suffix>` (e.g.
  `ubuntu-2604-server-3a4f5b`), where the suffix is the last six hex
  characters of the vSphere VM UUID (`/sys/class/dmi/id/product_uuid`).
  Stable across reboots of the same VM, unique across clones — eliminates
  the duplicate-hostname collision when multiple clones boot on a shared
  network. Runs once, gated by a sentinel at
  `/var/lib/packer-firstboot/hostname.done`, then disables itself.

## [1.0.0] — 2026-05-10

First production-ready cut of the Linux-only pipeline. All six Ubuntu LTS
templates (22.04 / 24.04 / 26.04 × server / desktop) build green on a single
Packer run.

### Added

- Ubuntu 22.04 LTS server and desktop templates.
- Ubuntu 24.04 LTS server and desktop templates.
- Ubuntu 26.04 LTS server and desktop templates with version-specific
  hardening (forked user-data templates, kernel boot params for OverlayFS
  oops, snap-seed suppression, additional firewall unit masks).
- GitHub Actions pipeline: `validate.yml` (PR check), `build-templates.yml`
  (manual + weekly cron, self-hosted runner), `upload-isos.yml` (manual ISO
  upload to vSphere Content Library).
- Template lifecycle pruning — retain N most-recent templates per
  `(version, type)` group; configurable via repo variables.
- `make secrets` helper to push `variables.pkrvars.hcl` values to GitHub
  Actions secrets in one step.
- SSH host key regeneration on first boot of cloned VMs via a oneshot
  systemd unit (works around socket-activated SSH on 22.04+).
- Machine-id preservation through the install reboot so Packer's SSH retry
  reaches the same DHCP lease, then truncation in `setup.sh` so each clone
  gets a fresh ID.
- Cloud-init neutralisation via `datasource_list: [None]` (intentionally
  not `cloud-init.disabled`, which breaks 24.04 networking).
- Slack success / failure notifications.
- Orphan-VM cleanup on workflow cancellation or failure.

### Removed

- Windows build support (Windows Server 2022 / 2025 / Windows 10).
  Preserved on the `feature/windows-support` branch for future
  reintroduction. The Linux-only main is simpler to maintain in isolation.

### Security

- LICENSE (MIT) and SECURITY.md added.

[Unreleased]: https://github.com/jameskilbycloud/packer/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jameskilbycloud/packer/releases/tag/v1.0.0

# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **26.04 OverlayFS kernel oops in curtin's rootfs-extract step — restored
  the workaround that PR #37 ("strip back to first principles") removed.**
  Build run 26602320872 (2026-05-28) hit a kernel oops in
  `ovl_iterate_merged` during subiquity's
  `Install/curtin_install/run_curtin_step/cmd-install/stage-extract` step,
  with `note: rsync[NNNN] exited with irqs disabled` on the console.
  This is the SAME bug the 2026-05-10 known-good notes documented and
  worked around with `overlay.metacopy=off overlay.redirect_dir=off` on
  the live-installer boot command — PR #37 removed those kernel params
  on the hypothesis that the subiquity `_send_update` loop was the only
  real bug, but the OverlayFS oops is independent and fires on its own
  cadence. Confirmed by console-screenshot in run 26602320872: the trace
  has nothing to do with subiquity's network module, it's deep in
  OverlayFS's iterate-merged codepath inside curtin's image-extract.
  Re-added the two strictly-required `overlay.metacopy=off
  overlay.redirect_dir=off` params on both 26.04 source blocks, sitting
  before the `---` separator alongside the existing `ipv6.disable=1` so
  both apply only to the live installer (not the installed OS). The
  older `overlay.index=off overlay.nfs_export=off` pair was defensive
  overkill in the original workaround and stays gone.
- **26.04 subiquity `_send_update: CHANGE ens33` loop — root cause and
  upstream-documented fix found.** Added `ipv6.disable=1` to the boot
  command (positioned before the `---` separator so it applies only to
  the live installer, not the installed OS). The loop is triggered by
  IPv6 address-change events firing as netlink CHANGE events;
  subiquity's network observer processes each one and re-triggers
  another, looping until `ssh_timeout`. Disabling IPv6 at the kernel
  level in the live installer removes the event source entirely.
  Reference: Launchpad question 698383
  (https://answers.launchpad.net/ubuntu/+source/ubiquity/+question/698383)
  reports the identical pattern (`_send_update: CHANGE ens<N>` flood)
  and the same workaround. Applied uniformly to 22.04 / 24.04 / 26.04
  boot commands for consistency; 22/24 weren't observed hitting the
  loop in production but the kernel param is harmless on those
  versions and keeps the boot command identical across versions.

### Changed

- **26.04 stripped back to first principles.** A week of layered
  workarounds (overlay kernel disables, snap-seed bypass, defensive boot
  command, RAM bump, settle wait, diag poller, three different netplan
  attempts) all turned out to be solving the wrong problems. The
  console-screenshot evidence proves the real bug is subiquity 26.04's
  Network module entering an infinite `_send_update: CHANGE ens33` loop
  on ~50% of attempts, regardless of autoinstall network configuration.
  Nothing we can do from autoinstall fixes it.
  - **Deleted**: `templates/server-2604-user-data.pkrtpl` and
    `templates/desktop-2604-user-data.pkrtpl` (now use the same shared
    `server-user-data.pkrtpl` / `desktop-user-data.pkrtpl` as 22.04 /
    24.04).
  - **Deleted**: `server_2604_ram_mb` variable. 26.04 server now uses the
    shared `server_ram_mb` default (4 GB).
  - **Deleted**: `server_2604_ssh_timeout` / `desktop_2604_ssh_timeout`
    locals. 26.04 uses the same `ssh_timeout` / `desktop_ssh_timeout` as
    other versions.
  - **Reverted**: 26.04 boot command — back to the standard
    `c<wait2>` / `linux /casper/vmlinuz --- autoinstall ds=nocloud` form
    used by 22.04 / 24.04. Dropped the double-spacebar, the
    overlay.metacopy/redirect_dir/index/nfs_export kernel disables, and
    `boot_keygroup_interval=100ms`.
  - **Removed from workflow**: 10-minute "settle wait" step
    (cluster-pressure hypothesis disproved), diagnostic poller step
    (data didn't help us; screenshots did).
  - **Removed from workflow**: SSH-timeout no-retry guard. With the
    90m fail-fast cap, retrying is affordable and probabilistic flake is
    exactly what retries are for. Both `Timeout waiting for SSH` and
    `Timeout waiting for IP` now retry once.
  - **Kept**: matrix split (PR #33 — 26.04 server + desktop are their
    own jobs, real reliability win), 90m fail-fast (PR #36), screenshot
    capture (PR #31), `-on-error=abort` for live failing VMs (PR #32).
- **ssh_timeout reduced from 120–180m to a flat 90m across all sources.**
  A healthy install reaches SSH in 5–15 min; anything still waiting at
  90m is hung (subiquity `_send_update` CHANGE loop, kernel oops in
  image-extract, etc.) and will not recover by waiting longer. Burning
  3h on a known-hung VM blocks the self-hosted runner and delays the
  diagnostic screenshot. Capping at 90m gets the failure signal back
  ~2× faster on the recurring 26.04 hang.

### Fixed

- **26.04 autoinstall `network:` section removed entirely; netplan now
  written via late-commands.** PR #34 (ens33-by-name) failed to fix the
  `_send_update: CHANGE ens33` loop — run 26411619708's 26.04-server
  hung 3h 17m with the *identical* screenshot pattern as before. The
  trigger isn't the netplan config (match vs name); it's subiquity's
  network observer subscribing to kernel netlink events for any
  interface, regardless of what we configure. Each CHANGE event fires
  `_send_update`, which appears to re-apply netplan, which triggers
  another kernel CHANGE event — infinite loop. By omitting `network:`
  from autoinstall, subiquity has no netplan to apply, and writing
  `/target/etc/netplan/01-ens33.yaml` in late-commands gives the
  installed OS the same DHCP config without going through subiquity's
  network module at install time.
- **26.04 user-data network config switched from `match: driver: vmxnet3`
  to `ens33` by name + `optional: true`.** Ground-truth screenshot from
  run 26397034336 (the new console-screenshot-on-failure step finally
  caught a live failing VM) showed subiquity's Network module stuck in
  an infinite `_send_update: CHANGE ens33` loop — the screen entirely
  full of `start:`/`finish:` log lines and a kernel warning about
  `drm_fb_helper_damage_work` hogging CPU from the log volume. The
  install pipeline ran ~6 min then this loop captured subiquity for the
  full `ssh_timeout` window. The `match: driver: vmxnet3` form (working
  fine on 22.04 / 24.04) intermittently triggers the loop on 26.04;
  naming the interface directly removes the trigger. Same fix in both
  server-2604 and desktop-2604 user-data templates.
- **26.04 in `all-linux` / `all` split into two separate matrix jobs.**
  Combining `2604-server` and `2604-desktop` in a single Packer
  invocation poisoned the desktop build: server completed fine, then
  desktop's install ran ~6 min and went idle (CPU cliff from ~2.4 GHz
  to 47 MHz, guest memory released from 6 GB to 81 MB, `bootTime`
  unchanged, hostname stuck at the live-installer default) until
  `ssh_timeout` exhausted at 3 h. Standalone `2604-desktop` in a fresh
  Packer process succeeds in ~24 min (verified run 26387407410). Same-
  process state leak in the vsphere-iso plugin is the suspected
  mechanism. PR #26 attempted to address the same symptom by going
  `parallel=1` within the combined entry but kept them in the same
  Packer process — that didn't fix it. Splitting into two matrix jobs
  gives each its own runner-side Packer process. PR #26's `parallel=1`
  exception no longer applies (each split entry is a single-target
  build) and the matrix comment is cleaned up to reflect the new
  understanding.
- 26.04-server: bumped default RAM from 4 GB to 8 GB via the new
  `server_2604_ram_mb` variable. At 4 GB, subiquity's snap-seeding step
  on 26.04 hangs intermittently — the install never reaches the
  post-seed reboot, and Packer's "Waiting for SSH" burns the full
  `ssh_timeout` budget. Suspected memory-pressure deadlock in
  subiquity's headless chroot when D-Bus-using snap postinsts run. The
  shared `server_ram_mb` default (4 GB) is unchanged for 22.04 / 24.04.

### Security

- **Templates no longer ship with build-only knobs.** A new
  `scripts/finalize.sh` provisioner runs after `vmtools.sh` and before
  `goss-validate.sh`, removing `/etc/sudoers.d/90-packer-${user}` (the
  NOPASSWD sudo entry) and `/etc/ssh/sshd_config.d/10-packer-pwauth.conf`
  (the `PasswordAuthentication yes` drop-in). Clones now require the
  user's password for sudo and accept SSH only via public-key auth (the
  Ubuntu 22.04+ default). `goss/server.yaml` flipped to assert these
  files are absent post-finalize.
- **Ephemeral per-build SSH keypair** generated by the workflow before
  each `packer build` run, injected into autoinstall via the new
  `build_ssh_authorized_keys` variable, and used by Packer via
  `build_ssh_private_key_file`. Keypair is wiped at job end. Plaintext
  passwords are no longer on the SSH path. `build_password` is still
  required because autoinstall hashes it for the user account and
  `shutdown_command` uses it for `sudo -S`.
- **GitHub Actions SHA-pinned.** All `actions/*` references replaced
  with commit-SHA pins (`actions/checkout@<sha> # v6` etc.). A
  compromised tag can no longer rewrite an action under the pipeline's
  feet. Dependabot bumps both the SHA and the trailing version comment
  natively.
- **Self-hosted runner privilege scoped down.** README setup now
  recommends pre-installing Packer / xorriso / govc as root one-time so
  the runner needs no sudo at all during normal operation. A
  command-scoped sudoers entry (not blanket NOPASSWD ALL) is documented
  as a fallback for users who want the auto-install paths to keep
  working.

### Added

- **Goss smoke tests** run as the last provisioner step on every build,
  asserting post-build state before Packer converts the VM to a template.
  If goss fails the build fails and the lifecycle prune step never runs,
  so a broken template cannot replace a known-good one. Spec files in
  `goss/` (server.yaml + desktop.yaml, with desktop extending server via
  gossfile). `build_username` is threaded into the spec via
  `--vars-inline` so the sudoers-file assertion tracks whatever you
  configured. The goss binary and spec are removed from the VM after
  validation, so they don't ship in the produced template.
- **Build retries on transient failures.** `packer build` is now wrapped
  in a one-retry loop with 60s backoff. Retry decision is driven by
  pattern-matching the Packer log: transient-looking patterns
  (`connection refused`, `i/o timeout`, `tls handshake`, etc.) trigger
  a single retry; everything else fails immediately so real bugs aren't
  masked. Tunable via the `MAX_ATTEMPTS` env var (default 2).
- Build metrics. After every successful `packer build`, the workflow emits
  `build-metrics-<label>-<run>.json` (90-day artifact, schema_version: 1)
  with duration, packer + plugin versions, GitHub run/actor/event/sha,
  and the embedded Packer manifest. The same data is rendered to
  `$GITHUB_STEP_SUMMARY` so it appears in the run UI. `setup.sh` also
  writes `/var/log/packer-build-info.json` (kernel, OS, package count,
  capture timestamp) and `/var/log/packer-package-list.txt` (full
  `dpkg -l` snapshot) into the produced template, so any clone can be
  inspected post-deploy for what was installed at template-build time
  and what has drifted since.
- Per-clone hostname uniquification via a `firstboot-hostname.service`
  oneshot systemd unit installed by `setup.sh`. Each clone boots with
  `<template-hostname>-<6-hex-suffix>` (e.g.
  `ubuntu-2604-server-3a4f5b`), where the suffix is the last six hex
  characters of the vSphere VM UUID (`/sys/class/dmi/id/product_uuid`).
  Stable across reboots of the same VM, unique across clones — eliminates
  the duplicate-hostname collision when multiple clones boot on a shared
  network. Runs once, gated by a sentinel at
  `/var/lib/packer-firstboot/hostname.done`, then disables itself.
- Pre-commit hook configuration in `.pre-commit-config.yaml`. Local install:
  `brew install pre-commit && pre-commit install`. Hooks run on every
  commit:
  - `packer fmt` (local hook, no third-party dep) — keeps HCL formatted.
  - `shellcheck` (via `shellcheck-py`) — `--severity=warning`, scoped to
    `scripts/*.sh`.
  - `yamllint` — relaxed rules tuned to the existing GitHub Actions style
    (configured in `.yamllint.yml`).
  - `gitleaks` — secrets scan on staged diff.
  - Standard hygiene hooks: trailing-whitespace, end-of-file-fixer,
    check-merge-conflict, check-added-large-files (max 500 KB),
    check-case-conflict, mixed-line-ending.
- New `.github/workflows/pre-commit.yml` workflow runs the same hook set
  on every PR via `pre-commit/action@v3.0.1`, so PRs are checked even if
  the contributor didn't `pre-commit install` locally.
- **Post-publish smoke test job** in `build-templates.yml`. After every
  successful build the new `smoke` job (one matrix entry per template)
  clones the just-built template, powers it on, injects an ephemeral
  ed25519 pubkey via the VMware Tools Guest Operations API (since
  `finalize.sh` disables SSH password auth on the template), SSHes in,
  re-runs `goss-validate.sh` against the spec under `sudo`, then
  destroys the clone in an `EXIT` trap. Closes the regression-class gap
  that the in-build goss can't see — first-boot oneshot ordering,
  cloud-init neutralisation breakage, open-vm-tools surviving the
  template conversion. A smoke failure marks the workflow run red.
  Implementation: `scripts/smoke-test.sh`.
- **`check-iso-updates.yml` workflow.** Weekly cron on Monday 06:00 UTC
  (plus manual dispatch). Compares the live-server ISO filename
  hardcoded in `scripts/upload-isos.sh` against the latest filename in
  `releases.ubuntu.com/<v>/SHA256SUMS`; on drift, rewrites every
  reference across tracked files via `git grep -l` + `perl -i`, pushes
  an `iso-bump-YYYYMMDD` branch, opens a PR with a summary table, and
  dispatches `upload-isos.yml` against the new branch so the ISO lands
  in the Content Library before merge. Detection runs on
  `ubuntu-latest` (single `curl` per version — no vSphere contact
  needed). Implementation: `scripts/check-iso-updates.sh`.
- **`rotate-templates.yml` workflow.** Monthly cron on the 1st at 03:00
  UTC (plus manual dispatch with `retain` / `name_pattern` / `dry_run`
  inputs). Prunes every `(version, role)` group in one pass,
  independent of the build cadence so old templates are removed even
  during quiet weeks. Shares the `packer-build` concurrency group with
  `build-templates.yml` so a scheduled rotation queues behind any
  in-flight build. The pruning logic was extracted from the in-build
  step into `scripts/prune-templates.sh` so both call sites share one
  implementation.
- **Packer plugin cache in `validate.yml`** via `actions/cache@v4`
  keyed on `hashFiles('packer.pkr.hcl')`. On cache hit `packer init`
  is a near no-op (~5 s saved per PR validation).
- **Status badges** at the top of the README for all five workflows
  (`build-templates`, `validate`, `pre-commit`, `check-iso-updates`,
  `rotate-templates`).
- **`docs/operations.md`** — operator reference split out of the
  README. Covers self-hosted runner setup, required vSphere + GitHub
  Actions permissions, per-workflow detail, build lifecycle (smoke +
  retention), and troubleshooting. README is now focused on quick
  reference + the GitHub-only deploy path; deep operator material
  lives in the new doc.
- **`CODE_OF_CONDUCT.md`** (Contributor Covenant 2.1) — required-ish
  for a polished public repo.

### Changed

- **README rewritten around a "Deploy from scratch — GitHub-only" path.**
  Replaces the previous six-step local-flavoured Quick start (`make
  init`, edit `pkrvars.hcl`, `openssl passwd`, `make upload-isos`,
  `make validate`, `make build`) with a seven-step GitHub web UI flow
  covering fork, Actions permissions, runner registration, secrets,
  optional variables, ISO seed, first build. Calls out the two genuine
  prerequisites outside GitHub (vCenter user + privileges, runner VM)
  up front. The local-build commands move to a "Running builds
  locally" section further down the doc, framed as the development
  alternative rather than the primary path.
- **Default template retention dropped from 4 to 2** (current + one
  rollback target). Configurable via the `TEMPLATE_RETENTION_COUNT`
  repository variable.
- **In-build prune step refactored to call the shared
  `scripts/prune-templates.sh`** rather than duplicating the logic
  inline in `build-templates.yml`.

### Fixed

- **`prune-templates.sh` no longer crashes on empty `by_group`** under
  `set -u`. When every matched VM is a non-template (typically a
  mid-build WIP from an in-flight run), the script now exits cleanly
  with "no templates to prune" rather than aborting with
  `by_group: unbound variable`. Tracks non-emptiness via an explicit
  sentinel counter so `${#assoc[@]}` / `${!assoc[@]}` is never invoked
  on a potentially-empty associative array. Also distinguishes
  "vm.info returned nothing" from "really not a template" in the skip
  log so an inspector can tell which case applies.

### Removed

- **`draft-post-review.md`** and **`build-monitor-status.md`** (repo
  root). Internal scratch files — a blog-post review and a Cowork
  session status report — that weren't referenced from anywhere.
- **`feature/windows-support`** remote branch (0 ahead of main, 46
  behind — no unique content).
- **`feat/windows-templates`** remote branch. Its one commit
  (`2be77c2` "kill unattended-upgrades in early-commands before
  desktop install") was already on main via the squashed commit
  `8334922` ("fix desktop unattended-upgrades deadlock").

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

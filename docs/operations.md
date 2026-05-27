# Operations — CI/CD and troubleshooting

Day-to-day this repo runs from GitHub Actions. This doc covers the parts that aren't part of the Quick start in the main [README](../README.md): how the workflows fit together, what the self-hosted runner needs, which permissions the vSphere account and the GitHub Actions token must have, the per-workflow reference, build lifecycle (smoke + retention), and troubleshooting.

## Overview

Six workflows cover the full pipeline. Nothing runs locally — secrets are set via the GitHub Settings UI, builds are triggered from the Actions tab, and everything else is on a schedule.

```
One-time setup (GitHub UI)         Ongoing automation
──────────────────────────         ──────────────────────────────────────
Settings → Secrets → add        ─► secrets available to all workflows
Settings → Runners → register
  the self-hosted runner

                                   PR opened
                                   └─► validate.yml + pre-commit.yml
                                       fmt check + packer validate + hooks
                                       (self-hosted, no secrets needed)

                                   Sundays 02:00 UTC / manual dispatch
                                   └─► build-templates.yml
                                       packer build → in-build goss →
                                       template → post-publish smoke clone
                                       (self-hosted runner)

Actions → Upload ISOs           ─► upload-isos.yml
  → Run workflow (initial seed)    govc library.import → Content Library
                                   (self-hosted, manual + auto-dispatched
                                    by check-iso-updates on new releases)

                                   Mondays 06:00 UTC
                                   └─► check-iso-updates.yml
                                       SHA256SUMS diff → bump PR + dispatch
                                       upload against the bump branch
                                       (self-hosted)

                                   1st of month 03:00 UTC
                                   └─► rotate-templates.yml
                                       prune all template groups
                                       (self-hosted)
```

> **After the one-time setup, no local tooling is needed.** Builds run automatically on the weekly schedule or on demand from the Actions UI. Push to `main` deliberately does *not* trigger a full build — PR validation is handled by `validate.yml`, and full builds are reserved for the schedule or an explicit `workflow_dispatch` so a routine code change cannot accidentally rebuild every template.

## Why a self-hosted runner

GitHub-hosted runners live on the public internet and cannot reach a private vCenter. A **self-hosted runner** installed on a machine inside your vSphere network solves this — it dials out to GitHub (port 443) to pick up jobs, so no inbound firewall rules are needed.

The runner machine needs:
- Outbound HTTPS to `github.com` and `*.actions.githubusercontent.com`
- Access to the vCenter API (port 443)
- Access to the VM network on port 22 (so Packer can SSH into the VM during the build)
- `curl`, `git`, and enough disk space to cache the Packer plugin (~50 MB)

A small Ubuntu VM on the same network as vCenter works well. The runner can be registered to a repository, organisation, or enterprise.

## Setting up the runner

1. In your GitHub repository go to **Settings → Actions → Runners → New self-hosted runner**
2. Follow the on-screen instructions to download and register the runner agent on your machine
3. Start the runner as a service so it survives reboots:

```bash
sudo ./svc.sh install
sudo ./svc.sh start
```

4. **Pre-install the workflow dependencies as root**, one time, so the runner user does *not* need sudo for normal operation. The workflow steps `Install Packer`, `Install xorriso`, and `Install govc` all check `command -v` first and skip the install if the tool is already on PATH. `gh` is also required (used by `check-iso-updates` to open the bump PR and dispatch the upload).

   ```bash
   # As root (or via interactive sudo, one-time)
   apt-get update && apt-get install -y xorriso curl python3 git perl unzip openssh-client
   # gh CLI (used by check-iso-updates to open the bump PR + dispatch upload)
   curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
     | tee /etc/apt/sources.list.d/github-cli.list
   apt-get update && apt-get install -y gh
   # Packer
   PACKER_VERSION=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/packer/latest \
     | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
   curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip" \
     -o /tmp/packer.zip && (cd /usr/local/bin && unzip -o /tmp/packer.zip) && rm /tmp/packer.zip
   # govc
   GOVC_VERSION=$(curl -fsSL https://api.github.com/repos/vmware/govmomi/releases/latest \
     | grep '"tag_name"' | cut -d'"' -f4)
   curl -fsSL "https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/govc_Linux_x86_64.tar.gz" \
     | tar -xzf - -C /usr/local/bin govc
   ```

   With these in place, the runner user only needs its own home directory and the GitHub Actions runner agent — no `sudoers` entry, no privilege escalation. This dramatically reduces the runner's blast radius if a workflow is ever compromised.

   **If you must keep sudo on the runner** (e.g. you want the workflow's auto-install paths to keep working), scope the entry to the specific commands rather than blanket `ALL`:

   ```bash
   cat <<'SUDOERS' | sudo tee /etc/sudoers.d/github-runner
   YOUR_RUNNER_USER ALL=(root) NOPASSWD: /usr/bin/apt-get update, \
     /usr/bin/apt-get install -y xorriso, \
     /bin/mv /tmp/packer /usr/local/bin/packer, \
     /bin/chmod +x /usr/local/bin/packer, \
     /bin/tar -xzf - -C /usr/local/bin govc
   SUDOERS
   ```

   This still grants enough for the install steps to work, while denying the runner ability to do anything else with sudo.

By default the workflows target any runner registered with the default `self-hosted` label (`runs-on: self-hosted`). To target a specific runner or label, set the **`RUNNER_LABEL`** repository variable:

**Settings → Secrets and variables → Actions → Variables → New repository variable**

| Variable | Example value | Effect |
|---|---|---|
| `RUNNER_LABEL` | `vsphere` | Targets runners with that label instead of `self-hosted` |

If `RUNNER_LABEL` is not set, the workflows fall back to `self-hosted`.

## Required permissions

Two sets of permissions need to be in place before the workflows can run end-to-end: the vCenter account used by Packer and govc, and the GitHub Actions token used by the workflows themselves.

### vSphere

Create a dedicated vCenter Single Sign-On user (e.g. `packer@vsphere.local`) and assign it a custom role with the privileges below. Granting `Administrator` works but is far broader than needed; the minimum set is published in HashiCorp's [vsphere-iso builder docs](https://developer.hashicorp.com/packer/integrations/hashicorp/vsphere/latest/components/builder/vsphere-iso#required-vsphere-privileges) — the groupings below summarise what each workflow needs.

**Used by `build-templates.yml` (Packer `vsphere-iso` builder):**

| Privilege group | Privileges |
|---|---|
| Datastore | Allocate space, Browse datastore, Low level file operations, Remove file, Update virtual machine files, Update virtual machine metadata |
| Network | Assign network |
| Resource | Assign virtual machine to resource pool |
| Virtual machine → Inventory | Create new, Create from existing, Remove, Register |
| Virtual machine → Configuration | Add new disk, Add or remove device, Advanced configuration, Change CPU count, Change memory, Change settings, Modify device settings, Remove disk, Set annotation, Toggle disk change tracking |
| Virtual machine → Interaction | Power on, Power off, Reset, Console interaction, Install VMware Tools |
| Virtual machine → Provisioning | Mark as template, Mark as virtual machine, Customize, Deploy template, Read customization specifications |
| Virtual machine → Snapshot management | Create snapshot, Remove snapshot |
| vApp | Import, View OVF environment, vApp instance configuration |
| Content Library | Read storage, Add library item, Update library item _(only if templates publish to a library)_ |
| Host → Local operations | Reconfigure virtual machine _(only when targeting an ESXi host directly via `VSPHERE_HOST`)_ |

**Used by `upload-isos.yml` (govc → Content Library):**

| Privilege group | Privileges |
|---|---|
| Datastore | Browse datastore, Allocate space, Low level file operations _(on the datastore backing the Content Library)_ |
| Content Library | Create local library, Add library item, Update library, Update library item, Read storage, Delete library item _(optional, only needed to replace an ISO)_ |

> **Tip:** assign the role at the Datacenter (or Cluster) level with **Propagate to children** enabled, and at the Content Library level separately. Avoid scoping it only at a folder — Packer needs visibility on the resource pool, datastore, and network objects, and a folder-level grant misses those.

### GitHub Actions

Three of the workflows (`build-templates`, `upload-isos`, `pre-commit`, `validate`) only need read access and the default `GITHUB_TOKEN` is enough. The `check-iso-updates` workflow needs to push a branch, open a PR, and dispatch `upload-isos.yml` — so two repository-level toggles must be enabled:

**Settings → Actions → General → Workflow permissions:**

1. Set **Workflow permissions** to **Read and write permissions** _(or leave it on "Read repository contents and packages permissions" — each workflow's own `permissions:` block grants what it needs, but the org/repo default must allow it)_.
2. Tick **Allow GitHub Actions to create and approve pull requests**. Without this, `gh pr create` fails with `GraphQL: GitHub Actions is not permitted to create or approve pull requests`.

The workflow-level `permissions:` block in [`.github/workflows/check-iso-updates.yml`](../.github/workflows/check-iso-updates.yml) requests exactly what it uses:

```yaml
permissions:
  contents: write        # push the iso-bump-YYYYMMDD branch
  pull-requests: write   # open the bump PR
  actions: write         # dispatch upload-isos.yml against the new branch
```

If your repository lives under an organisation, the same two toggles also exist at **Organization → Settings → Actions → General** and the org-level setting wins. Enable them there if a per-repo change has no effect.

## GitHub Secrets

Add each secret via **Settings → Secrets and variables → Actions → New repository secret**. Re-paste the new value any time it changes; secrets are overwritten in place.

| Secret | Source variable | Description |
|---|---|---|
| `VSPHERE_SERVER` | `vsphere_server` | vCenter URL, e.g. `https://vcenter.example.com` |
| `VSPHERE_USER` | `vsphere_user` | vCenter username |
| `VSPHERE_PASSWORD` | `vsphere_password` | vCenter password |
| `VSPHERE_INSECURE` | `vsphere_insecure_connection` | `true` to skip TLS verification |
| `VSPHERE_DATACENTER` | `vsphere_datacenter` | Datacenter name |
| `VSPHERE_CLUSTER` | `vsphere_cluster` | Cluster name (blank if using `VSPHERE_HOST`) |
| `VSPHERE_HOST` | `vsphere_host` | ESXi host (blank if using `VSPHERE_CLUSTER`) |
| `VSPHERE_DATASTORE` | `vsphere_datastore` | Datastore for VM storage |
| `VSPHERE_NETWORK` | `vsphere_network` | Port group / network name |
| `VSPHERE_FOLDER` | `vsphere_folder` | VM folder for finished templates |
| `VSPHERE_ISO_DATASTORE` | `vsphere_iso_datastore` | Datastore or Content Library name holding ISOs |
| `VSPHERE_ISO_LIBRARY_DATASTORE` | `vsphere_iso_library_datastore` | Datastore backing the Content Library (upload workflow). Defaults to `vsphere_datastore` if unset. |
| `BUILD_USERNAME` | `build_username` | OS user created during install |
| `BUILD_PASSWORD` | `build_password` | Plaintext build password |
| `BUILD_PASSWORD_ENCRYPTED` | `build_password_encrypted` | SHA-512 hash — `openssl passwd -6 '<password>'` |
| `UBUNTU_2204_ISO_PATH` | `ubuntu_2204_iso_path` | ISO filename/path for 22.04 |
| `UBUNTU_2404_ISO_PATH` | `ubuntu_2404_iso_path` | ISO filename/path for 24.04 |
| `UBUNTU_2604_ISO_PATH` | `ubuntu_2604_iso_path` | ISO filename/path for 26.04 |

## Workflow: validate

**File:** [`.github/workflows/validate.yml`](../.github/workflows/validate.yml)

**Triggers:** Every pull request that touches `.pkr.hcl` files, templates, or provisioner scripts. Also runs on push to `main` and can be triggered manually.

**Runner:** the same self-hosted runner the rest of the pipeline uses. No real secrets are needed — `packer validate` checks syntax and variable references only and never contacts vSphere — but running it on the same runner keeps the "everything against the runner you control" model intact. Placeholder values are passed for required variables.

**What it does:**

1. Installs Packer and downloads the vsphere plugin (`packer init`)
2. Runs `packer fmt --check` — fails the PR if any file needs reformatting (fix with `packer fmt .` locally)
3. Runs `packer validate` against all six builds — catches undefined variables, bad HCL, and broken `templatefile()` references before anything reaches main

This gives fast feedback (typically under 2 minutes) on every PR with no infrastructure cost. The vsphere Packer plugin is cached via `actions/cache@v4` keyed on the hash of `packer.pkr.hcl` so `packer init` is a near no-op on cache hit.

## Workflow: build-templates

**File:** [`.github/workflows/build-templates.yml`](../.github/workflows/build-templates.yml)

**Triggers:**

- **Manual** (`workflow_dispatch`) — choose a specific template or `all`, with an optional dry-run (validate only) toggle
- **Schedule** — rebuilds all templates every Sunday at 02:00 UTC, picking up the latest security updates

> **No push trigger.** Push to `main` runs `validate.yml` only. Full builds require an explicit `workflow_dispatch` or the weekly cron, so routine code changes do not rebuild every template.

**What it does:**

1. Resolves which builds to run into a matrix based on the trigger/input
2. Matrix entries run **sequentially** on the self-hosted runner (`max-parallel: 1`) — one Packer process at a time. Where applicable, parallelism happens *inside* a single Packer process via `-parallel-builds=2` (combined "ubuntu-XXXX.*" runs build server + desktop together)
3. **Pre-flight secrets check** — fails immediately with a clear list of any missing secrets before any tools are installed
4. Installs Packer via direct binary download (codename-independent — works on any Ubuntu release), runs `packer init`, then `packer validate`
5. Runs `packer build` with `PACKER_LOG=1` for full debug output
6. Uploads the Packer log and build manifest as workflow artifacts
7. **Prunes old templates** — retains the most-recent N templates per `(version, type)` group and destroys the rest (see [Template lifecycle](#template-lifecycle))
8. **Captures build metrics** — emits `build-metrics-<label>-<run>.json` (90-day artifact) with duration, packer + plugin versions, GitHub run/actor/event/sha, and the embedded Packer manifest. The same fields are rendered to `$GITHUB_STEP_SUMMARY` so they show in the run UI without downloading the artifact (see [Build metrics](#build-metrics))
9. Always deletes the temporary credentials file, even on failure

Once the build job succeeds for a matrix entry, the [`smoke`](#post-publish-smoke-test) job clones the produced template and exercises its first-boot behaviour.

**Running manually:**

Go to **Actions → Build Packer Templates → Run workflow**, pick a target, and optionally enable dry-run to validate without building.

```
workflow_dispatch inputs:
  build_target → 2404-server | 2404-desktop | all-servers | all | …
  dry_run      → false (default) | true
```

## Template lifecycle

After every successful build the workflow prunes older templates so vSphere does not silently accumulate ~52 dated templates per variant per year. Pruning is grouped by `(version, type)` — `ubuntu-2604-server-*` and `ubuntu-2604-desktop-*` are independent groups, so a combined "build both" run keeps N of each, not N total interleaved.

Implementation lives in [`scripts/prune-templates.sh`](../scripts/prune-templates.sh). It is called from two places: the in-build step in [`build-templates.yml`](../.github/workflows/build-templates.yml) (which only sees the just-built variant) and the standalone [`rotate-templates.yml`](../.github/workflows/rotate-templates.yml) workflow (which prunes every group in one pass).

Configure via repository variables (**Settings → Secrets and variables → Actions → Variables**):

| Variable | Default | Effect |
|---|---|---|
| `TEMPLATE_RETENTION_COUNT` | `2` | Templates kept per `(version, type)`. `2` = current + one rollback target. |
| `TEMPLATE_PRUNE_DRY_RUN` | `false` | Set `true` to log the destroy plan without executing it. Useful for the first run to confirm the right entries are matched. |

Safety properties of the prune step:

- Only runs after `success() && dry_run == false` — a failed build, or a packer dry-run, never destroys anything.
- Only acts on items that are actually templates (`Config.Template == true`) — a concurrent build's WIP VM cannot be pruned.
- Sorts by name descending; because the `YYYYMMDD` suffix is zero-padded, lex desc is equivalent to newest-first, so the just-built template is always retained.
- A failure to destroy any single template is logged and the loop continues — one stuck template does not block pruning of the rest.

## Build metrics

Every successful build emits two artefacts of metadata so the pipeline is observable without external infrastructure:

**Workflow-level (`build-metrics-<label>-<run>.json`, 90-day artifact)** — written by the workflow after `packer build` succeeds and uploaded alongside the manifest. Schema (v1):

```json
{
  "schema_version": 1,
  "label": "2604-server",
  "version": "2604",
  "manifest": "ubuntu-2604",
  "build_count": 1,
  "duration_seconds": 3247,
  "duration_human": "0h54m07s",
  "started_at": "2026-05-10T02:00:12Z",
  "completed_at": "2026-05-10T02:54:19Z",
  "packer_version": "Packer v1.15.3",
  "plugin_versions": "github.com/vmware/vsphere v2.1.2",
  "github": {
    "run_id": "...",
    "run_number": 142,
    "actor": "jameskilbycloud",
    "event": "schedule",
    "sha": "...",
    "ref": "refs/heads/main"
  },
  "manifest_data": { /* Packer's manifest verbatim */ }
}
```

The same fields are rendered as a markdown table to `$GITHUB_STEP_SUMMARY`, so they appear at the top of the workflow run page without downloading the artifact.

**Guest-side (lives inside the produced template)** — written by `setup.sh` so any clone can be inspected post-deploy:

| File | Contents |
|---|---|
| `/var/log/packer-build-info.json` | `{kernel_version, os_pretty_name, package_count, captured_at}` — JSON, ~200 B |
| `/var/log/packer-package-list.txt` | Full `dpkg -l` snapshot at template-build time (~200 KB) |

Useful patterns:

```bash
# What was installed when this template was built?
ssh clone cat /var/log/packer-build-info.json

# What has changed since the template was built?
ssh clone "diff <(dpkg -l) /var/log/packer-package-list.txt"

# How long did the latest build of 2404-server take?
gh run download --pattern 'build-metrics-2404-server-*' \
  && jq '.duration_human' build-metrics-2404-server-*/build-metrics-2404-server.json
```

## Smoke tests (Goss)

Every build runs a [Goss](https://github.com/goss-org/goss) validation pass against the in-flight VM **after** all provisioners but **before** Packer converts the VM to a template. If goss fails, the build fails — and because the lifecycle prune step only runs on success, a broken template can never replace a known-good one.

Spec files live in `goss/`:

- `goss/server.yaml` — universal post-build assertions: sudoers entry for the build user, cloud-init neutralisation file, SSH host keys absent (regenerated on first boot), first-boot oneshot units enabled, `open-vm-tools` running, swap off, UFW masked, build-metadata snapshots present, etc.
- `goss/desktop.yaml` — desktop-only additions on top of the server spec via gossfile include: `ubuntu-desktop-minimal`, `open-vm-tools-desktop`, `gdm3` enabled.

`build_username` is threaded into the spec via goss's `--vars-inline`, so the sudoers-file assertion (`/etc/sudoers.d/90-packer-<username>`) tracks whatever you set as the `BUILD_USERNAME` secret.

`scripts/goss-validate.sh` downloads goss (pinned via `GOSS_VERSION`, default `v0.4.9`), runs `goss validate --format documentation`, and removes the binary + spec afterwards so neither ships in the produced template.

To extend: add new file/service/command/package assertions to `goss/server.yaml` (or `goss/desktop.yaml` for desktop-only). The expected runtime cost per build is ~30 seconds.

## Post-publish smoke test

The in-build goss pass above runs **before** Packer converts the VM to a template, so it can't catch regressions that only surface on the cloned, first-boot template — first-boot oneshot ordering (e.g. `ssh-host-keygen.service` vs `rootfs-rw`), cloud-init neutralisation breakage, open-vm-tools not surviving the template conversion, etc.

The `smoke` job in [`build-templates.yml`](../.github/workflows/build-templates.yml) closes that gap. After every successful build it:

1. Locates the newest template matching `ubuntu-<version>-<role>-*` via `govc find`.
2. Clones it (powered off), assigns it a transient name (`smoke-<template>-<run-id>`), powers it on.
3. Waits up to 10 minutes for VMware Tools to report an IP.
4. Injects an ephemeral ed25519 pubkey via the VMware Tools Guest Operations API (the template has SSH password auth disabled by [`finalize.sh`](../scripts/finalize.sh), so password SSH login is not an option — `govc guest.upload` bypasses sshd entirely).
5. SSHes in with the matching private key, runs `scripts/goss-validate.sh` against the spec under `sudo` (the build user is in the `sudo` group but `finalize.sh` removes the NOPASSWD drop-in, so `echo $BUILD_PASSWORD | sudo -S` is used).
6. Destroys the clone in an `EXIT` trap regardless of pass/fail.

Smoke failure marks the workflow run red. Fan-out: one matrix entry per (version, role), so a combined `all-linux` build produces six smoke runs.

Implementation: [`scripts/smoke-test.sh`](../scripts/smoke-test.sh). Configurable via the same `BUILD_USERNAME` / `BUILD_PASSWORD` / vSphere secrets the build itself uses — no extra setup beyond the existing secrets.

**Known limitation:** the in-build prune step (which keeps the most recent N templates per group) runs in the build job before smoke runs, so a failed smoke does not stop the new (broken) template from displacing the oldest in the retention window. With `TEMPLATE_RETENTION_COUNT=2` you still have the previous (known-good) template as a rollback target, but the third-oldest will be gone.

## Build retries

`packer build` is wrapped in a one-retry loop in [`build-templates.yml`](../.github/workflows/build-templates.yml). The retry decision is driven by pattern-matching the Packer log:

- **Transient patterns** (retried after a 60s backoff): `connection refused`, `i/o timeout`, `tls handshake`, `no route to host`, `temporary failure`, `service unavailable`, `context deadline exceeded`, `cannot connect`, `dial tcp`, `server closed`, `unexpected EOF`, `connection reset`. These cover vSphere DRS migrations, ISO datastore hiccups, and general network blips.
- **Permanent patterns** (failed immediately): everything else — provisioner script failures, validation errors, missing variables, goss assertion failures. Retrying on these would just mask real bugs.

`-on-error=cleanup` ensures Packer destroys any partial VM between attempts; `-force` lets the retry overwrite leftover artefacts. Tunable via `MAX_ATTEMPTS` env var on the step (default 2).

## Workflow: upload-isos

**File:** [`.github/workflows/upload-isos.yml`](../.github/workflows/upload-isos.yml)

**Trigger:** Manual only — run this once during initial setup or whenever Ubuntu releases a new point version. The `check-iso-updates` workflow also dispatches this automatically when it opens a bump PR.

**What it does:** Runs `scripts/upload-isos.sh` on the self-hosted runner, downloading ISOs from `releases.ubuntu.com` and importing them into your vSphere Content Library via govc. Installs govc automatically if not present on the runner.

```
workflow_dispatch inputs:
  ubuntu_versions  → "2204 2404 2604" (default) or any subset
  content_library  → "Packer-ISOs" (default)
  download_dir     → "/var/tmp/packer-isos" (default)
  keep_downloads   → false | true
  skip_checksum    → false | true
```

## Workflow: check-iso-updates

**File:** [`.github/workflows/check-iso-updates.yml`](../.github/workflows/check-iso-updates.yml)

**Triggers:**

- **Schedule** — every Monday at 06:00 UTC, picking up Ubuntu point releases (`22.04.X`, `24.04.X`, `26.04.X`) within a week of release.
- **Manual** (`workflow_dispatch`) — run on demand from the Actions UI.

**Runner:** the same self-hosted runner. The detection is a single `curl` per version against `https://releases.ubuntu.com/<v>/SHA256SUMS`; no vSphere contact is needed, but running it on the self-hosted runner keeps the workflow inside your network boundary.

**What it does:**

1. Runs `scripts/check-iso-updates.sh` in detect-only mode and compares the live-server ISO filename hardcoded in `scripts/upload-isos.sh` against the latest filename in the upstream SHA256SUMS.
2. If any version has drifted **and** no `iso-bump-*` PR is already open:
   - Re-runs the script with `--apply`, which uses `git grep -l` + `perl -i` to rewrite every reference to the old filename across tracked files (Packer variables, upload script, build workflow ISO map, README).
   - Pushes an `iso-bump-YYYYMMDD` branch and opens a PR with a summary table of current vs latest.
   - Dispatches `upload-isos.yml` against the new branch (`gh workflow run --ref <branch>`) so the new ISO is pushed into the Content Library before the PR is merged. Running against the branch (not `main`) is critical — the filename map only exists in its updated form on the branch.
3. If everything is up to date, the workflow exits early with a single log line.

The single source of truth for the "current" filename is the `ISO_FILENAME` map in `scripts/upload-isos.sh` — the detection script reads from there to avoid maintaining a duplicate list. If you ever want to dry-run the detection by hand, the script can be invoked directly (`bash scripts/check-iso-updates.sh` for detect-only, `bash scripts/check-iso-updates.sh --apply` to rewrite filenames across tracked files), but the scheduled workflow handles this automatically.

## Workflow: rotate-templates

**File:** [`.github/workflows/rotate-templates.yml`](../.github/workflows/rotate-templates.yml)

**Triggers:**

- **Schedule** — 1st of every month at 03:00 UTC. Prunes every `(OS, role)` group in one pass, independent of the build cadence so old templates are removed even during quiet weeks.
- **Manual** (`workflow_dispatch`) — useful for one-off prunes; `retain`, `name_pattern`, and `dry_run` are exposed as inputs so you can preview a destroy plan before committing.

**Runner:** self-hosted (needs vCenter access).

**What it does:** runs `scripts/prune-templates.sh` against all templates matching `ubuntu-*` (or the override pattern), keeping the most recent `TEMPLATE_RETENTION_COUNT` per group and destroying the rest. Same script as the in-build prune step in `build-templates.yml`, just driven without a fresh build first.

**Concurrency:** shares the `packer-build` concurrency group with `build-templates.yml`, so a scheduled rotation queues behind any in-flight build rather than racing to destroy a template a build is currently producing.

## Concurrency

The build workflow uses a `concurrency` group (`packer-build`) so that only one build pipeline runs at a time — preventing two jobs from racing to create VMs with the same name in vSphere. A queued run waits for the current one to finish rather than being cancelled. `rotate-templates.yml` shares the same group so a scheduled rotation queues behind any in-flight build.

---

## Troubleshooting

**`Error: No builds to run` with `-only` flag**
Packer's full source reference format is `<build-label>.<source-type>.<source-name>` (e.g. `ubuntu-2404-server.vsphere-iso.ubuntu-2404-server`). Passing just `vsphere-iso.ubuntu-2404-server` does not match. Use a glob: `-only='*.vsphere-iso.ubuntu-2404-server'`. The Makefile and workflows already use this format.

**`vcenter_server is required` / `ssh_username must be specified` errors**
The build workflow pre-flight check will list exactly which secrets are absent before Packer runs. Go to **Settings → Secrets and variables → Actions** and add any missing secrets.

**Runner not picking up jobs**
Check the label the runner was registered with (visible in **Settings → Actions → Runners**). If it does not match `self-hosted`, set the `RUNNER_LABEL` repository variable to the correct label. See [Setting up the runner](#setting-up-the-runner).

**Runner sudo prompt blocks job**
The workflow's auto-install paths for Packer / xorriso / govc need sudo. Either pre-install them as root (recommended — eliminates the need for sudo on the runner entirely; see [Setting up the runner](#setting-up-the-runner)), or grant a tightly scoped sudoers entry as described there.

**Build hangs at `Waiting for SSH`**
The VM booted but Packer cannot reach port 22. Check that the machine running Packer has network access to the VM's subnet. Temporarily set `PACKER_LOG=1` and watch the boot sequence via the vSphere console.

**`autoinstall` not triggering / VM boots to live shell**
The boot command uses GRUB's command line (`c`) to inject kernel parameters. If the GRUB menu layout changes between Ubuntu point releases the timing or keystrokes may need adjusting. Increase `boot_wait` in the source block (e.g. `"10s"`) and check the GRUB prompt appears before characters are typed.

**Checksum mismatch on ISO download**
Ubuntu occasionally re-releases point ISOs with updated checksums. Re-run the upload script — it will re-download and replace the file. If the ISO filename has changed (e.g. `22.04.5`), update `ISO_FILENAME[2204]` in `scripts/upload-isos.sh` and the `ubuntu_2204_iso_path` variable. The `check-iso-updates` workflow now does this automatically on a weekly cron.

**`govc library.import` fails**
Ensure the datastore has enough free space for the ISO (typically 1–2 GB each). Check that the vCenter user has the `Content library > Add library item` privilege.

**`disk_size` errors**
Disk size is specified in MB internally (`var.server_disk_gb * 1024`). If you see validation errors, confirm your `server_disk_gb` / `desktop_disk_gb` values are plain integers with no units.

**Desktop build times out on SSH**
Installing `ubuntu-desktop-minimal` takes significantly longer than a server install. SSH timeouts live in `locals.pkr.hcl` — `desktop_ssh_timeout = 120m` for 22.04 / 24.04 desktop, `desktop_2604_ssh_timeout = 180m` for 26.04 desktop, `server_2604_ssh_timeout = 180m` for 26.04 server (which also has a longer install on the GA kernel), and `ssh_timeout = 90m` for 22.04 / 24.04 server. If your environment is slow, raise the relevant local.

**Prune script reports `skip (not a template)` for every VM**
A build is in flight (the VMs exist during install but aren't templates until Packer's convert-to-template step at the end), or a previous build failed before conversion. The script intentionally refuses to touch non-templates — they could belong to a concurrent run. Wait for the in-flight build to finish, or if these are confirmed orphans from a failed build, destroy them manually with `govc vm.destroy`.

# Operations — CI/CD and troubleshooting

> Covers: Packer 1.14+ · vSphere 7.0+ · Ubuntu 22.04 / 24.04 / 26.04 LTS · GitHub Actions self-hosted runner.

Day-to-day this repo runs from GitHub Actions. This doc covers the parts that aren't part of the Quick start in the main [README](../README.md): how the workflows fit together, what the self-hosted runner needs, which permissions the vSphere account and the GitHub Actions token must have, the per-workflow reference, build lifecycle (smoke + retention), and troubleshooting.

## Overview

Six workflows cover the full pipeline. Nothing runs locally — secrets are set via the GitHub Settings UI, builds are triggered from the Actions tab, and everything else is on a schedule.

```text
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

4. **Pre-install the workflow dependencies as root**, one time, so the runner user does *not* need sudo for normal operation.

   Every workflow has an `Install <tool>` step (or equivalent) that attempts a best-effort auto-install for the tool it needs — `command -v` is checked first and the step is a no-op if the tool is already on PATH. All of these install steps are marked `continue-on-error: true` so a failed auto-install (no sudo, broken APT, network glitch) does **not** block the job: the workflow proceeds, and the downstream step that actually calls the tool surfaces a clear `command not found`. The auto-install is a convenience, not a contract — pre-installing is the supported path.

   The full set of tools every workflow expects on the runner:

   | Tool         | Used by                                                                                   | Auto-installed by                                  |
   |--------------|-------------------------------------------------------------------------------------------|----------------------------------------------------|
   | `packer`     | `build-templates`, `validate`, `pre-commit` (the `packer-fmt` hook)                       | All three workflows                                |
   | `xorriso`    | `build-templates` (cloud-init CD image creation)                                          | `build-templates`                                  |
   | `govc`       | `build-templates`, `upload-isos`, `rotate-templates` (Content Library + template pruning) | All three workflows                                |
   | `pre-commit` | `pre-commit`                                                                              | `pre-commit` (system → `pip --user` fallback)      |
   | `gh`         | `check-iso-updates` (opens the bump PR + dispatches `upload-isos`)                        | `check-iso-updates`                                |
   | `cloud-init` | `validate` (user-data schema lint via `scripts/lint-user-data.sh`)                        | `validate`                                         |

   The shell utilities `curl`, `python3`, `git`, `perl`, `unzip`, and `openssh-client` are assumed already present on the runner and are not auto-installed — install them once as part of the runner base image.

   To pre-install the lot, become root first with `sudo -i` and paste the block below, **or** prefix every line with `sudo`. Mixing `sudo apt-get update && apt-get install …` will fail with `Could not open lock file /var/lib/dpkg/lock-frontend` because the chained `&&` only carries sudo across to the first command.

   ```bash
   # Run as root (sudo -i first, or prefix each line with sudo)

   # System packages
   apt-get update
   apt-get install -y \
     xorriso curl python3 git perl unzip openssh-client pre-commit cloud-init

   # gh CLI (used by check-iso-updates to open the bump PR + dispatch upload)
   curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
     > /etc/apt/sources.list.d/github-cli.list
   apt-get update
   apt-get install -y gh

   # Packer
   PACKER_VERSION=$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/packer/latest \
     | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
   curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip" \
     -o /tmp/packer.zip
   (cd /usr/local/bin && unzip -o /tmp/packer.zip)
   rm /tmp/packer.zip

   # govc
   GOVC_VERSION=$(curl -fsSL https://api.github.com/repos/vmware/govmomi/releases/latest \
     | grep '"tag_name"' | cut -d'"' -f4)
   curl -fsSL "https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/govc_Linux_x86_64.tar.gz" \
     | tar -xzf - -C /usr/local/bin govc
   ```

   > **Note on Python on the runner:** no workflow uses `actions/setup-python` — the runner's system `python3` is used directly (the pre-commit workflow needs it for hook invocation, the user-data lint workflow needs it for the rendering harness in `lint-user-data.sh`). Pre-installing `pre-commit` as above means the hook chain never has to `pip install` at job time, which dovetails with the no-sudo-during-jobs goal.

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

Four of the workflows (`build-templates`, `upload-isos`, `pre-commit`, `validate`) only need read access and the default `GITHUB_TOKEN` is enough. The `check-iso-updates` workflow needs to push a branch, open a PR, and dispatch `upload-isos.yml` — so two repository-level toggles must be enabled:

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
| `VSPHERE_ISO_LIBRARY_DATASTORE` | (workflow env var, not a Packer var) | Datastore backing the Content Library where the ISOs live. Only needed by `upload-isos.yml` to create the library the first time; the build workflow resolves the actual backing datastore at runtime from the Content Library metadata via `govc library.info`. |
| `BUILD_USERNAME` | `build_username` | OS user created during install |
| `BUILD_PASSWORD` | `build_password` | Plaintext build password |
| `BUILD_PASSWORD_ENCRYPTED` | `build_password_encrypted` | SHA-512 hash — `openssl passwd -6 '<password>'` |
| `ADMIN_USERNAME` (optional) | `admin_username` | Persistent admin account created by `setup.sh`. Leave empty to skip admin-user creation. |
| `ADMIN_GITHUB_USER` (optional) | `admin_github_user` | GitHub username whose public keys are imported into the admin account via `ssh-import-id-gh`. Leave empty to skip key import. |
| `SLACK_WEBHOOK_URL` (optional) | (workflow env var, not a Packer var) | Slack incoming-webhook URL for build success / failure notifications. If unset, the notify steps log "SLACK_WEBHOOK_URL not set — skipping." and exit cleanly. |

> **No ISO-path secrets.** ISO paths and the ISO backing datastore are resolved at workflow runtime from the Content Library — `build-templates.yml` calls `govc library.info -json` to discover both the per-version ISO item and the datastore that hosts it. This means new Ubuntu point releases (e.g. `22.04.5` → `22.04.6`) work automatically once the new ISO is uploaded; there's nothing to edit in repository secrets.

## Workflow: validate

**File:** [`.github/workflows/validate.yml`](../.github/workflows/validate.yml)

**Triggers:** Every pull request that touches `.pkr.hcl` files, templates, or provisioner scripts. Also runs on push to `main` and can be triggered manually.

**Runner:** the same self-hosted runner the rest of the pipeline uses. No real secrets are needed — `packer validate` checks syntax and variable references only and never contacts vSphere — but running it on the same runner keeps the "everything against the runner you control" model intact. Placeholder values are passed for required variables.

**What it does:**

1. Installs Packer and downloads the vsphere plugin (`packer init`)
2. Runs `packer fmt --check` — fails the PR if any file needs reformatting (fix with `packer fmt .` locally)
3. Runs `packer validate` against all six builds — catches undefined variables, bad HCL, and broken `templatefile()` references before anything reaches main
4. Runs [`scripts/lint-user-data.sh`](../scripts/lint-user-data.sh) — renders each `templates/*-user-data.pkrtpl` with placeholder values and pipes the result through `cloud-init schema --config-file -`. `packer validate` treats the user-data body as opaque text; this step catches malformed cloud-config, un-nested netplan, bad `early-commands` / `late-commands` shapes, etc. without needing a real Packer build to expose them.

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

```text
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
    "actor": "<github-username>",
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

Every build validates the produced VM with [Goss](https://github.com/goss-org/goss) at two distinct moments in the template lifecycle, because the assertions that hold at one moment don't necessarily hold at the other. Four spec files in `goss/`:

| Spec | When it runs | Asserts |
|---|---|---|
| `goss/server.yaml` | In-build, last provisioner before Packer converts the VM to a template | Build-time state of the **template itself** |
| `goss/desktop.yaml` | Same, but includes server.yaml via `gossfile` + adds `ubuntu-desktop-minimal`, `gdm3`, etc. | As above, plus desktop additions |
| `goss/server-clone.yaml` | Post-publish, on a **clone** of the just-built template, after first-boot oneshots have fired | Post-first-boot state of a **clone** |
| `goss/desktop-clone.yaml` | Same, but includes server-clone.yaml + the desktop assertions | As above, plus desktop additions |

The build-time and clone-time specs share most of their content (sudoers/SSH/cloud-init drop-ins; firstboot unit existence; sysctl / package / open-vm-tools state). They differ in three places where the first-boot oneshots flip state:

| Assertion | Build (`server.yaml`) | Clone (`server-clone.yaml`) |
|---|---|---|
| `/etc/ssh/ssh_host_rsa_key` exists | `false` (wiped by `setup.sh`) | `true` (regenerated by `ssh-host-keygen.service` on first boot) |
| `/etc/ssh/ssh_host_ed25519_key` exists | `false` | `true` (same reason) |
| `ssh-host-keygen.service` enabled | `true` (queued to fire on next boot) | `false` (it ran on the clone's first boot then self-disabled) |
| `firstboot-hostname.service` enabled | `true` | `false` (same pattern) |
| `/var/lib/packer-firstboot/hostname.done` exists | not asserted | `true` (sentinel touched by `firstboot-hostname.sh`) |

Both specs are full duplicates of the assertions they share rather than `gossfile` includes with overrides — goss's behaviour on duplicate-keys-across-includes isn't well-documented and tests inconsistently between versions. When you add an assertion that holds in both moments, mirror it in both pairs (`server.yaml` + `server-clone.yaml`; the desktop variants inherit via gossfile-include of their server counterpart).

`build_username` is threaded into both specs via goss's `--vars-inline`, so the sudoers-file assertion (`/etc/sudoers.d/90-packer-<username>`) tracks whatever you set as the `BUILD_USERNAME` secret.

[`scripts/goss-validate.sh`](../scripts/goss-validate.sh) downloads goss (pinned via `GOSS_VERSION`, default `v0.4.9`), runs `goss validate --format documentation`, and removes the binary + spec afterwards so neither ships in the produced template. The same script is used for both the in-build and the post-publish pass — only the spec path differs.

Runtime cost: ~30 s for the in-build pass (already-booted VM), ~80–90 s for the post-publish pass (includes cloning + boot + goss). Adding new assertions to either pair costs negligibly more.

## Post-publish smoke test

The in-build goss pass above asserts the **template's** state. It can't catch regressions that only surface on a **clone** after first boot — and that's where most subtle template bugs hide. Two real examples this smoke job has already caught:

- **`firstboot-hostname.service` failing on every clone** due to `tr -d '-\n'` mis-parsing the leading dash as a flag. Service exited `failed`, `ExecStartPost=disable` never fired, sentinel never written, hostname never uniquified. Build-time goss couldn't see it because the unit hadn't fired yet.
- **Clone hostname collisions** if the hostname-uniquification unit silently fails (same root cause). Multiple clones boot with the template's stock hostname, breaking DNS / monitoring / Slack-bot-correlation on shared networks.

### How it works

The `smoke` job in [`build-templates.yml`](../.github/workflows/build-templates.yml) runs after every successful matrix entry of the build job. For each (version, role) produced, [`scripts/smoke-test.sh`](../scripts/smoke-test.sh) does:

1. **Locate the just-built template.** `govc find . -type m -name "ubuntu-<version>-<role>-*"`, then `govc object.collect -s <path> config.template` per match to identify the template (rather than a WIP VM from an in-flight build). The script chooses the highest-dated match. **Don't** use `govc vm.info -json | parse-the-config-tree` for this — its JSON shape varies between govc versions and silently mis-classifies real templates.
2. **Clone.** `govc vm.clone -on=false -vm <template>` to a transient name `smoke-<template>-<run-id>`, scoped to `VSPHERE_FOLDER` + `VSPHERE_CLUSTER` (or `VSPHERE_HOST`) + `VSPHERE_DATASTORE`.
3. **Power on + wait for VMware Tools IP.** Up to `SMOKE_TIMEOUT_SECONDS` (default 600 s) for `govc vm.ip` to return a non-empty address.
4. **Inject an ephemeral SSH pubkey via the VMware Tools Guest Operations API.** A fresh ed25519 keypair is generated locally on the runner; the pubkey is `govc guest.upload`'d to `/tmp/smoke-pubkey-<run-id>` on the clone; a `govc guest.run /bin/sh -c "mkdir + mv + chmod"` then puts it at `~/$BUILD_USERNAME/.ssh/authorized_keys` with correct perms. The keypair is wiped on the runner at script exit. Why not `sshpass` + the build password: [`finalize.sh`](../scripts/finalize.sh) removes the build-time `PasswordAuthentication yes` drop-in, so the clone refuses password SSH login — guest.upload bypasses sshd entirely.
5. **Wait for SSH port 22.** Up to `SSH_TIMEOUT_SECONDS` (default 240 s) for TCP connect to succeed.
6. **Copy goss spec + validator + run goss.** `scp` every `goss/*.yaml` to `/tmp/` (so any `gossfile:` include resolves), then SSH in and run `scripts/goss-validate.sh` against `goss/server-clone.yaml` (or `goss/desktop-clone.yaml`) under `sudo`. The build user is in the `sudo` group but `finalize.sh` removed the NOPASSWD drop-in, so the script uses `echo "$BUILD_PASSWORD" | sudo -S`.
7. **Destroy the clone in an `EXIT` trap.** Captures the script's true exit code via `_exit_rc=$?` as the FIRST thing in the trap body (the `rm` cleanup that follows would otherwise clobber `$?` to 0). Powers off + destroys the clone regardless of pass/fail.

Fan-out: one matrix entry per (version, role) — a combined `all-linux` build produces six independent smoke runs. The matrix entries don't share state; each clones from its own template.

### When smoke fails

On any non-zero exit, the EXIT trap runs a **diagnostic dump via VMware Tools Guest Operations** before destroying the clone. The dump runs even when sshd is broken — it doesn't need SSH. The dump script is uploaded as a file (`/tmp/smoke-diag-<run-id>.sh`) then invoked with `govc guest.run /bin/sh <path>`; inlining via `sh -c "<multi-line>"` doesn't work because vmtoolsd's `arguments` parameter doesn't preserve newlines.

The dump emits, in one log frame:

- **Live hostname + `/etc/hostname`** — did `firstboot-hostname.service` complete?
- **`systemctl is-system-running`** — did the boot reach a stable state?
- **`is-active` + `is-enabled` for every relevant service** — `ssh.service`, `ssh.socket`, `sshd.service`, `ssh-host-keygen.service`, `firstboot-hostname.service`.
- **`/var/lib/packer-firstboot/` listing** — did the firstboot oneshots write their sentinels?
- **First 30 lines of `/usr/local/sbin/firstboot-hostname.sh`** on the clone — quick check that the template has the script version you expect (not a stale copy from before a fix).
- **Full `journalctl -u firstboot-hostname`** — exact failure mode if the unit aborted.
- **`journalctl -u ssh-host-keygen` tail** — same for the SSH host-key regen.
- **`systemctl --failed`** — every failed unit on the clone.

The dump header line `--- govc guest.run rc=N, output bytes=M ---` tells you whether the call itself succeeded; `rc=0, bytes=0` means the call ran but produced no output (auth issue, or vmtoolsd not responding).

### Interpreting a smoke failure

| Failure shape | What it usually means |
|---|---|
| Build green, smoke red on goss assertions you didn't change | A first-boot regression. Read the diagnostic dump's `journalctl -u <service>` tail for the actual error. |
| `❌ No template (config.template=true) found among matches` | The build didn't actually convert to template (rare — Packer's `convert_to_template = true` is set), or the smoke job is racing a still-in-flight build. Wait + retry. |
| `❌ Clone did not report an IP within N seconds` | DHCP problem, VMware Tools not starting in time, or the network the clone landed on can't reach vCenter. Smoke needs DHCP on the target VM network. |
| `❌ SSH on <ip>:22 not reachable within N seconds` | The clone got an IP but sshd never opened. Diagnostic dump will fire next — read `is-active` for ssh.service / ssh.socket / ssh-host-keygen.service. |

### Known limitations

- **Smoke runs after the in-build prune step.** The prune step retires old templates inside the build job, before the separate smoke job fires. A failed smoke does NOT roll back the just-built (broken) template — it's already in the retention window. With `TEMPLATE_RETENTION_COUNT=2` you still have the previous (presumably good) template as a rollback target, but the third-oldest will be gone. Acceptable trade-off given the typical N=2 retention.
- **Each smoke clone needs a free name slot** (no name collisions with concurrent builds). The transient name `smoke-<template>-<run-id>` is unique per workflow run.
- **The smoke clone is destroyed unconditionally** on EXIT. For deep manual debugging, set `CLONE_NAME=keep-this-one` env on a local invocation of `smoke-test.sh` — the EXIT trap still tries to destroy it, but you can disable that by commenting out the trap. Don't do this in CI.

## Build retries

`packer build` is wrapped in a one-retry loop in [`build-templates.yml`](../.github/workflows/build-templates.yml). The retry decision is driven by pattern-matching the Packer log:

- **Transient patterns** (retried after a 60s backoff): `connection refused`, `i/o timeout`, `tls handshake`, `no route to host`, `temporary failure`, `service unavailable`, `context deadline exceeded`, `cannot connect`, `dial tcp`, `server closed`, `unexpected EOF`, `connection reset`. These cover vSphere DRS migrations, ISO datastore hiccups, and general network blips.
- **Permanent patterns** (failed immediately): everything else — provisioner script failures, validation errors, missing variables, goss assertion failures. Retrying on these would just mask real bugs.

`-on-error=abort` leaves the failing VM running and intact so the downstream "Capture console screenshot" step can grab a PNG of whatever's on screen at the failure point. A separate "Destroy orphaned VM" step in the workflow cleans up any leftover VMs between retry attempts so vSphere inventory still ends clean. `-force` lets the retry overwrite leftover artefacts (e.g. a partial Packer manifest). Tunable via `MAX_ATTEMPTS` env var on the step (default 2).

## Workflow: upload-isos

**File:** [`.github/workflows/upload-isos.yml`](../.github/workflows/upload-isos.yml)

**Trigger:** Manual only — run this once during initial setup or whenever Ubuntu releases a new point version. The `check-iso-updates` workflow also dispatches this automatically when it opens a bump PR.

**What it does:** Runs `scripts/upload-isos.sh` on the self-hosted runner, downloading ISOs from `releases.ubuntu.com` and importing them into your vSphere Content Library via govc. Installs govc automatically if not present on the runner.

```text
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

**Workflow step fails with `command not found` for `packer` / `xorriso` / `govc` / `pre-commit` / `gh` / `cloud-init`**
The matching `Install <tool>` step is `continue-on-error: true`, so a failed auto-install marks itself with ⚠️ and lets the workflow keep going — meaning the next step that calls the tool is what actually fails. Look at the `Install <tool>` step's log to see *why* the auto-install didn't run (most often: no sudo on the runner, broken third-party APT repo, network egress blocked). Then pre-install the tool as root per [Setting up the runner](#setting-up-the-runner) — that's the supported path and eliminates the need for sudo on the runner entirely. Alternatively, grant a tightly scoped sudoers entry as described in that section.

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
SSH timeouts live in `locals.pkr.hcl` — `ssh_timeout = 30m` for all server sources and `desktop_ssh_timeout = 30m` for all desktop sources (22.04, 24.04, 26.04). Both used to be 90m+; the cap was tightened to 30m for fail-fast behaviour after observing clean builds finish their SSH-wait phase in ~15–20 min. Healthy environments have ~50% headroom; if your vCenter / network is genuinely slow, raise the relevant local. The trade-off: with `MAX_ATTEMPTS=2` a stuck template's worst-case is ~70 min (30m + 60s backoff + 30m) instead of the previous ~3h, which keeps retries against the probabilistic 26.04 OverlayFS oops affordable.

**Prune script reports `skip (not a template)` for every VM**
A build is in flight (the VMs exist during install but aren't templates until Packer's convert-to-template step at the end), or a previous build failed before conversion. The script intentionally refuses to touch non-templates — they could belong to a concurrent run. Wait for the in-flight build to finish, or if these are confirmed orphans from a failed build, destroy them manually with `govc vm.destroy`.

# Review — "Automating vSphere Golden Images with Packer and GitHub Actions"

Comparison of the WordPress draft (post 8653) against the actual codebase in this repo.

## Verdict in one line

The post is **broadly accurate** on the technical "how it works" sections, but has **three factual errors** that should be fixed before publishing, plus a number of typos and one section that is materially out of sync with what the repo now does.

---

## High-impact issues — fix before publishing

### 1. The post claims push-to-`main` triggers a build. It doesn't.

The post says (Workflow 2):

> Trigger: Push to main (when .pkr.hcl files or scripts change), weekly cron (every Sunday at 02:00 UTC to pick up security updates), or manual dispatch.

And later, in Step 8:

> Every push to main that touches a .pkr.hcl file, autoinstall template, or provisioner script triggers a fresh build of the affected templates.

But `.github/workflows/build-templates.yml` actually has only `workflow_dispatch` and `schedule`. The push trigger has explicitly been removed, with this comment in the file:

> The push trigger has been removed from this workflow to prevent unintended full builds on every code change — use workflow_dispatch to trigger a deliberate build.

`README.md` has the same drift on line 517 — that's where the post likely picked it up. Fix the post and the README together: the build workflow only runs on schedule (Sunday 02:00 UTC) or on manual dispatch.

### 2. The post says "up to six templates" — the repo now builds nine.

The post frames the whole pipeline as Ubuntu-only ("six vSphere templates: 22.04 / 24.04 / 26.04 × server / desktop") and lists six rows in the hardware table. But the repo also has:

- `windows-server-2022.pkr.hcl`
- `windows-server-2025.pkr.hcl`
- `windows-10.pkr.hcl`
- `templates/windows-server-autounattend.pkrtpl`, `templates/windows-10-autounattend.pkrtpl`
- `scripts/windows/{bootstrap,install-vmtools,configure,sysprep}.ps1`
- All the `windows_*` variables in `variables.pkr.hcl`
- Makefile targets `windows-server-2022`, `windows-server-2025`, `windows-10`, `windows`
- Workflow build matrix entries `windows-server-2022`, `windows-server-2025`, `windows-10`, `all-windows`, `all`

The README's first paragraph already says "nine templates in total." The post needs to either (a) add a Windows section, or (b) explicitly scope itself to Ubuntu and say "the repo also builds Windows; that's a separate post." Right now it reads as if Windows isn't there.

This also makes the snippet `make build-all # Build all six images sequentially` wrong — `build-all: 2204 2404 2604 windows` builds nine.

### 3. The parallelism architecture is described incorrectly.

The post says (Workflow 2):

> Matrix strategy: A resolve-targets job converts the trigger input … into a build matrix, then each template runs as a parallel job — up to six simultaneous builds.

That's not what the workflow does. Looking at `build-templates.yml`:

- Workflow-level concurrency uses `group: packer-build` with `cancel-in-progress: false`, so a second run **queues** rather than running alongside.
- The matrix `strategy` sets `max-parallel: 1` — only one matrix entry runs at a time.
- Parallelism happens *inside* a single Packer process via `-parallel-builds=N` (set to `2` for combined Ubuntu version builds, `1` otherwise).
- The comment in the file is explicit: "Inside a single run, parallelism happens at the Packer level (one `build {}` block with multiple sources + `-parallel-builds=N`), not via the matrix."

So the correct description is closer to: "the matrix dispatches one Packer run per Ubuntu version (or per Windows edition), each entry runs sequentially, and inside each entry Packer builds server + desktop in parallel via `-parallel-builds=2`." This is also why there's a single self-hosted runner and `max-parallel: 1` — one Packer process per runner.

---

## Medium-impact issues

### 4. A copy-paste-ready snippet has a typo that will break setup

In Step 2:

> ```
> echo "$USER ALL=(ALL) NOPASSWOD" | sudo tee /etc/sudoers.d/github-runner
> ```

`NOPASSWOD` should be **`NOPASSWD`** (one O). Anyone copy-pasting this gets a syntactically invalid sudoers file and `visudo` will reject it on next use. This is the kind of error that will generate "doesn't work" comments.

### 5. "Libary" → "Library", "upto" → "up to date"

The intro paragraph has "vSphere Content **Libary**" twice and "**upto** date template". Worth a proofread pass — they're in the most-read part of the post.

### 6. Project-structure tree is incomplete

The structure diagram shows only the Ubuntu-side files. Missing entries that exist in the repo:

```
windows-server-2022.pkr.hcl
windows-server-2025.pkr.hcl
windows-10.pkr.hcl
templates/windows-server-autounattend.pkrtpl
templates/windows-10-autounattend.pkrtpl
scripts/desktop.sh                     # ubuntu-desktop-minimal install
scripts/set-github-secrets.sh          # backs `make secrets`
scripts/windows/bootstrap.ps1
scripts/windows/install-vmtools.ps1
scripts/windows/configure.ps1
scripts/windows/sysprep.ps1
variables.pkrvars.hcl.example
manifests/                             # written here after each build
```

Even if you scope the post to Ubuntu, `set-github-secrets.sh` and `desktop.sh` should be shown — you reference both via `make secrets` and the desktop variant.

### 7. The "Running Builds Locally" example mismatches the actual Makefile

The post shows:

```
packer build -var-file .pkrvars.hcl -only='*.vsphere-iso.ubuntu-2404-server' .
```

The actual Makefile invocation is:

```
packer build -var-file=variables.pkrvars.hcl -on-error=cleanup -only='*.vsphere-iso.ubuntu-2404-server' .
```

Three differences: filename is `variables.pkrvars.hcl`, the flag uses `=`, and `-on-error=cleanup` is omitted from the post snippet. Use the actual command — it's pedagogically the same point and the reader can copy it.

### 8. `setup.sh` description omits the most interesting bit

The post says setup.sh does "full apt upgrade … disables swap, removes SSH host keys, appends SSH hardening config … zeroes free disk space … optionally creates a named admin account." Accurate but understated. The script also:

- Installs a oneshot **`ssh-host-keygen.service`** systemd unit that regenerates host keys on the first boot of each clone, *before* `ssh.socket` and `ssh.service`. The script's own comment explains why this matters: on Ubuntu 22.04+ socket activation means `ssh-keygen@.service` is never triggered, so without this unit cloned VMs come up with no host keys and refuse SSH connections. This is a substantive, non-obvious fix and is exactly the kind of detail that justifies a "homelab golden image pipeline" post over just `apt install packer`.
- Truncates `/etc/machine-id` so each clone gets a fresh ID (and DHCP lease) on first boot.
- Writes sysctl tunings (`vm.swappiness=10`, increased `inotify` watches).

I'd add at least the SSH-host-keygen detail — it's a strong "I hit this in production and here's the fix" moment.

---

## Low-impact / proofreading

### 9. Codename for 26.04

The post and codebase both call 26.04 "Plucky." Plucky Puffin was 25.04 (April 2025). When 26.04 LTS actually releases, its codename will follow the alphabet from `Q…` / `R…`, not `P…`. Worth either dropping the codename or marking it as TBC. (Also affects `ubuntu-2604.pkr.hcl` line 2 and the `ubuntu_2604_iso_path` description in `variables.pkr.hcl`.)

### 10. Trailing prose nits

- "The post details the automation of … Then progressing on to build LTS templates …" — sentence fragment, second sentence has no subject.
- "( obviously I use Ubuntu)" — extra space after the bracket; reads slightly off.
- "To implement this you are going to need a Github account" — no comma; "GitHub" is the canonical capitalisation (you use it correctly elsewhere).
- "On my Mac I utilise brew for these tools" — "I use brew" reads cleaner.

---

## Things the post gets right (worth keeping)

For balance — these are all accurate against the code:

- Plugin requirement: `vsphere >= 1.3.0` — matches `packer.pkr.hcl`.
- Hardware sizing in the table (2/2/40 server, 4/4/60 desktop) — matches the variable defaults in `variables.pkr.hcl`.
- EFI / pvscsi / vmxnet3 / LVM thin / open-vm-tools / SSH hardening / zeroed disk — correct.
- The `cidata` ISO approach (vs hosting an HTTP autoinstall server) — correct.
- The `match: driver: vmxnet3` rationale — correct, this is exactly what the templates do.
- `datasource_list: [None]` written via late-commands and the explanation about why `cloud-init.disabled` breaks 24.04 networking — correct and well-explained.
- `admin_username` / `admin_github_user` and `ssh-import-id-gh` — exactly matches the variables and `setup.sh`.
- Validate workflow: `ubuntu-latest`, `packer fmt -check` + `packer validate` with placeholder vars — correct.
- Cron `"0 2 * * 0"` = Sundays 02:00 UTC — correct.
- xorriso install step — correct.
- govc Content Library path resolution `contentlib-{lib-uuid}/{item-uuid}/…` — correct.
- Pre-flight secrets check that fails fast — correct.
- `runner.pkrvars.hcl` written from secrets and unconditionally deleted — correct.
- Artifact retention 30 days for log, 90 days for manifest — matches the workflow.
- Concurrency group `packer-build`, `cancel-in-progress: false` — correct.
- Orphan-VM cleanup on `cancelled() || failure()` — correct.
- VM naming `ubuntu-2404-server-<YYYYMMDD>` — matches `local.build_date = formatdate("YYYYMMDD", timestamp())`.
- `*.vsphere-iso.ubuntu-2404-server` glob and the explanation about `<build-label>.<source-type>.<source-name>` — correct.
- "GitHub-hosted runners can't reach private vCenter" rationale — correct and well-explained.

---

## Suggested edit order

1. Fix the two factual claims (push-to-main trigger, "up to six templates" / `build-all`).
2. Fix the `NOPASSWOD` typo.
3. Decide whether the post covers Windows or explicitly scopes to Ubuntu, and update the title/excerpt/structure tree to match.
4. Rewrite the parallelism paragraph in Workflow 2.
5. Proofread pass for "Libary" / "upto" / spacing.
6. Optionally: add one sentence to the `setup.sh` description about the SSH host-key regen service.

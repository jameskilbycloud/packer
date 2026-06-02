# Security Policy

## Reporting a vulnerability

If you have found a security issue in this repository — for example, a way for
the build pipeline to execute attacker-controlled code, a credential disclosure
in the workflow, or a misconfiguration that produces an insecure template by
default — please report it privately rather than opening a public issue.

**Preferred channel:** [GitHub private vulnerability reporting](https://github.com/jameskilbycloud/packer/security/advisories/new).
This creates a private advisory visible only to maintainers.

**Fallback:** email `james@jameskilby.cloud` with `[security] packer` in the
subject line.

When reporting, please include:

- A short description of the issue and its impact.
- The commit SHA on `main` (or the branch / PR) where you observed it.
- Reproduction steps or a minimal proof-of-concept if you have one.
- Any suggested mitigation, if you've thought about it.

You will get an initial acknowledgement within seven days on a best-effort
basis. There is no bug bounty — this repo is one of the personal projects
under the [`jameskilbycloud`](https://github.com/jameskilbycloud) org, not
commercial software — but fixes will be prioritised over feature work and
you will be credited in the release notes if you'd like.

## Scope

| In scope | Out of scope |
|---|---|
| Packer HCL configuration in this repo | Vulnerabilities in upstream Ubuntu, the vsphere-iso plugin, govc, or vSphere itself — please report those to their respective projects |
| Shell and PowerShell provisioner scripts | Misconfigurations introduced after a user customises their fork |
| GitHub Actions workflows in `.github/workflows/` | The user's own self-hosted runner host — its hardening is the user's responsibility |
| Default settings that produce an insecure template | Issues that require an attacker who already has vCenter admin credentials |

## Supported versions

Only the current `main` branch is supported. There are no maintained release
branches; once a fix is merged, users should pull the latest `main` and rebuild.

## Known security considerations

These are properties of how the pipeline works that may surprise consumers,
documented here so they can be designed around rather than reported repeatedly:

- **The build user account persists in clones, with its password set in
  `/etc/shadow`.** This is the same posture as a stock Ubuntu install where
  the install-time user is created during the autoinstall flow. The
  build-only escalation knobs — passwordless sudo via
  `/etc/sudoers.d/90-packer-${BUILD_USERNAME}` and the
  `/etc/ssh/sshd_config.d/10-packer-pwauth.conf` drop-in that enables SSH
  password authentication — are explicitly removed by
  [`scripts/finalize.sh`](scripts/finalize.sh) before template conversion,
  and [`goss/server.yaml`](goss/server.yaml) /
  [`goss/desktop.yaml`](goss/desktop.yaml) assert the post-finalize state
  on every build. Net effect on clones: SSH accepts only pubkey auth (no
  password), and any `sudo` invocation prompts for the build user's
  password. If your security model requires removing the build user
  entirely or rotating its password, that remains a post-clone
  configuration-management task.
- **UFW is masked in produced templates.** This is intentional during the
  build (to avoid blocking SSH on first boot post-clone) but means clones
  ship without a firewall. Re-enable in your deployment pipeline.
- **Self-hosted runner with passwordless sudo.** The runner setup
  documented in `README.md` previously recommended blanket NOPASSWD sudo
  for the runner user. As of the current revision, the recommended
  setup is to pre-install Packer, xorriso, and govc as root (one-time)
  so the runner needs no sudo at all during normal operation; a
  command-scoped sudoers entry is documented as a fallback. Audit
  existing runners — if you set up the runner before this change, the
  blanket entry may still be in place at `/etc/sudoers.d/github-runner`.

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
basis. There is no bug bounty — this is a personal homelab project — but
fixes will be prioritised over feature work and you will be credited in the
release notes if you'd like.

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

- **Build credentials are present in clones by default.** The build user has
  passwordless sudo and SSH password auth is enabled in the produced
  template. This is a known gap and is tracked separately from this policy.
  A "harden for clone" provisioner is planned; until then, treat freshly
  built templates as not yet ready for production deployment without an
  additional finalisation step.
- **UFW is masked in produced templates.** This is intentional during the
  build (to avoid blocking SSH on first boot post-clone) but means clones
  ship without a firewall. Re-enable in your deployment pipeline.
- **Self-hosted runner with passwordless sudo.** The runner setup
  documented in `README.md` grants the runner user passwordless sudo. This
  makes the runner a high-value target. Scope down per the README's
  hardening notes if you are running this in a multi-tenant context.

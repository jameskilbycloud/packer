# Contributing

Thanks for the interest. This is one of the personal projects under the
[`jameskilbycloud`](https://github.com/jameskilbycloud) org — homelab work,
not commercial software. Contributions are welcome but the bar is "fits the
existing patterns and doesn't break the six Linux builds."

## Release & change-management policy

Pre-v1.0.0 (through 2026-06-02), commits landed directly on `main` — the
repo was in extended-debugging mode and direct pushes kept the iteration
loop fast. The full history of that period is in
[CHANGELOG.md](CHANGELOG.md) under `[0.9.0]` and `[1.0.0]`.

From v1.0.1 onward the rule is **PR-first**:

- All fixes, features, and dependency / workflow changes open a PR
  against `main` and squash-merge once CI is green.
- Dependabot bumps are PRs by construction; merge via the PR UI.
- Maintainer direct-push to `main` is reserved for release-cut
  bookkeeping (CHANGELOG promotion, annotated tag prep) and clearly
  trivial fixes (broken link, README typo). Anything that touches
  Packer HCL, scripts, workflows, or autoinstall templates goes
  through a PR.

## Quick start

1. **Fork** the repository and create a branch off `main` named for the
   change (e.g. `fix/2604-...`, `feat/...`, `chore/...`, `docs/...`).
2. **Install pre-commit hooks** (one-time, recommended):
   ```bash
   brew install pre-commit         # or: pip install pre-commit
   pre-commit install
   ```
   This wires up `packer fmt`, `shellcheck`, `yamllint`, `gitleaks`, and
   the standard hygiene hooks defined in `.pre-commit-config.yaml`. They
   run automatically on every `git commit`. To run them on demand against
   the whole repo: `pre-commit run --all-files`.
3. Make your change.
4. **Run `packer fmt .`** before committing — the validate workflow rejects
   PRs whose HCL files need reformatting. The pre-commit hook above does
   this automatically; if you skipped step 2, run it by hand.
5. **Run `packer validate .`** locally with placeholder vars (the
   `validate.yml` workflow does the same on PRs, so this catches problems
   early). For example:
   ```bash
   packer validate \
     -var='vsphere_server=x' \
     -var='vsphere_user=x' \
     -var='vsphere_password=x' \
     -var='vsphere_datacenter=x' \
     -var='vsphere_cluster=x' \
     -var='vsphere_datastore=x' \
     -var='vsphere_network=x' \
     -var='vsphere_iso_datastore=x' \
     -var='build_password=x' \
     -var='build_password_encrypted=x' \
     .
   ```
6. **Open a pull request** against `main`.

## Commit message style

Follows [Conventional Commits](https://www.conventionalcommits.org/) loosely.
Looking at recent history is the fastest way to match the style:

```
fix(2604): disable overlay.metacopy and overlay.redirect_dir to avoid kernel oops
chore: remove Windows support from main; preserved on feature/windows-support
docs: README accuracy pass against current state of main
feat(workflow): prune old templates after each successful build
```

The scope (`(2604)`, `(setup)`, `(workflow)`) is optional but useful when
the change is localised. Keep the subject line ≤ 72 chars; put the
"why" in the body.

## What to test before opening a PR

- **HCL changes:** `packer fmt -check` and `packer validate` (above).
- **Workflow YAML:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/<file>.yml'))"`.
- **Shell scripts:** ideally `shellcheck`, though there's no enforced CI gate yet.
- **Functional impact on the produced template:** unfortunately the only way
  to test this for now is to run the relevant `make <target>` against your
  own vSphere. If the change touches `setup.sh`, `desktop.sh`, `vmtools.sh`,
  or any `*-user-data.pkrtpl`, please confirm at least one full build succeeds.

## Coding conventions

- **Comments explain *why*, not *what*.** The existing files lean heavily on
  this — there's a lot of "this looks weird because [actual upstream bug]"
  documentation. Match that style.
- **No emoji** in code or commits unless explicitly asked.
- **No new top-level files** without a reason. The repo is intentionally
  flat; new top-level files should pull weight (a new build target, a new
  governance doc, a new workflow).
- **Don't commit `variables.pkrvars.hcl`** — `.gitignore` covers
  `*.pkrvars.hcl` so this should be impossible accidentally, but worth
  remembering.

## Reviewing other PRs

PRs are auto-assigned to maintainers via [CODEOWNERS](.github/CODEOWNERS).
Anyone is welcome to leave review comments regardless.

## If you're forking

A few files reference the canonical repo's GitHub identity directly —
after forking, search-and-replace these to your own org/user so badges,
review routing, and contact links work:

- `README.md` — badge URLs (`github.com/jameskilbycloud/packer/...`)
- `.github/CODEOWNERS` — `* @jameskilbycloud`
- `SECURITY.md` — security disclosure contact
- `CONTRIBUTING.md` — this file (issue/PR links)
- `CHANGELOG.md` — repo-link refs at the bottom

`git grep jameskilbycloud` lists everything in one go.

## Reporting bugs / requesting features

Use the issue templates at
**[Issues → New issue](https://github.com/jameskilbycloud/packer/issues/new/choose)**
rather than opening a blank issue — the templates prompt for the information
that makes a bug actually fixable (versions, exact failure mode, log excerpts).

For *security* issues, see [SECURITY.md](SECURITY.md) — please do not open
a public issue.

<!--
Thanks for the contribution. The structure below matches the style used in
recent PRs on this repo. Delete sections that don't apply, but please keep
the Summary and Verification at minimum.
-->

## Summary

<!-- 1–3 bullet points: what does this change, and why? Link any related issue. -->

## Files changed

<!-- Optional. Useful for larger PRs to give the reviewer a roadmap. -->

## Verification

- [ ] `packer fmt -check .` passes
- [ ] `packer validate .` passes (with placeholder vars — see CONTRIBUTING.md)
- [ ] If touching a workflow file: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/<file>'))"` parses cleanly
- [ ] If functional: at least one of the affected build matrix entries built end-to-end against real vSphere

<!--
For changes that affect produced templates (setup.sh, desktop.sh, vmtools.sh,
*-user-data.pkrtpl, or hardware variables), the only meaningful test is a
real build. Please note in the PR which target you actually built.
-->

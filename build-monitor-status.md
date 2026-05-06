# Packer Build Monitor — Status Report

**Run checked:** [#117 (run ID 25406356867)](https://github.com/jameskilbycloud/packer/actions/runs/25406356867)
**Checked at:** 2026-05-06

## Result: Unable to retrieve status

This scheduled monitoring task cannot reach the GitHub Actions run from the Cowork sandbox. None of the available access methods worked:

| Method | Result |
|---|---|
| `https://github.com/jameskilbycloud/packer/actions/runs/25406356867` | HTTP 404 |
| `https://github.com/jameskilbycloud/packer/actions` | HTTP 404 |
| `https://api.github.com/...` | Blocked — host not on egress allowlist |
| `gh` CLI in sandbox | Not installed |

The 404 on the run URL almost certainly means **the `jameskilbycloud/packer` repo is private**. Unauthenticated `WebFetch` from this sandbox cannot read private repos.

## What needs to change for this monitor to work

Pick one of the following:

1. **Add `api.github.com` to the network allowlist** (Settings → Capabilities) and provide a `GITHUB_TOKEN` the task can use. This is the cleanest fix — the task could then call the REST API and parse job status reliably.
2. **Make the repo public.** Then `WebFetch` against `github.com` would work without auth.
3. **Run the monitor outside Cowork** — e.g. as a local script that uses your authenticated `gh` CLI and pipes results somewhere this task can read (a webhook, a file in the workspace, etc.).
4. **Switch the trigger** — have the workflow itself post status to Slack or a file on completion (the workflow already has Slack hooks; you could rely on those instead of polling).

## Where the matrix jobs would have come from

For reference, the workflow matrix (from `.github/workflows/build-templates.yml`) builds these labels:

- `2204-server`, `2204-desktop`
- `2404-server`, `2404-desktop`
- `2604-server`, `2604-desktop`

Server timeout is 240 minutes; combined runs use `-parallel-builds=2`.

## Recommendation

Stop or pause this scheduled task until access is sorted, otherwise it will keep producing the same "cannot reach" report on every run.

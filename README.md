# ci-events-playground

Manual test bed for CI-watching bots (built for the
[ghbuildrobot](https://github.com/Glitchy-Sheep) Go SDK, usable for any
bot that polls GitHub PRs and Actions). Every PR lifecycle event and
every failing job conclusion is one `make` target away, driven entirely
by `gh` and `git`.

The repo is public on purpose: GitHub-hosted Actions runners are free on
public repos, and draft PRs are not available on free-plan private repos.

## Setup

```sh
gh auth login          # once
make init              # once: creates the GitHub repo and pushes main
```

Point a bot at it, for example:

```sh
go run ./examples/ghwatch \
  --repo Glitchy-Sheep/ci-events-playground --user Glitchy-Sheep \
  --job 'glob:Build *' --interval 10s --fetch-logs
```

## How scenarios work

The `SCENARIO` file at the repo root selects the CI behavior: line 1 is
the scenario name, line 2 is a timestamp so every scenario PR has a
non-empty diff (and a guaranteed inline-comment anchor).
`make pr SCENARIO=<name>` opens a PR whose branch sets that file; the
`Prep` job reads it and fans out to four jobs with stable names:
`Build FE` (matched by `ExactJob("Build FE")` and the `Build *` glob),
`Build BE` (glob only), `Lint` and `Unit Test` (never matched, control
jobs). Switch the scenario on a live PR with
`make scenario PR=<n> SCENARIO=<name>` (the push doubles as a head-change
event), or re-run without a push via
`make dispatch PR=<n> SCENARIO=<name>`.

## Scenario matrix

| scenario | Build FE | Build BE | Lint | Unit Test | exercises |
|---|---|---|---|---|---|
| success | pass | pass | pass | pass | job_discovered, job_concluded(success) |
| fail-early | 40k lines, compile errors at ~2%, exit 1 | pass | pass | pass | full-log fetch; tail-only printing misses the error |
| fail-middle | 40k lines, panic at ~50%, exit 1 | pass | pass | pass | same, middle |
| fail-late | 40k lines, test failure at the end, exit 1 | pass | pass | pass | tail printing works here |
| fail-multi | 300 lines, exit 1 | 300 lines, exit 1 | pass | 300 lines, exit 1 | two matched failures plus one unmatched (must stay silent) |
| timeout | sleep 300, killed by timeout-minutes 1 | pass | pass | pass | conclusion cancelled with a timeout annotation, ~60-70s |
| cancel-me | sleep 1800 until `make cancel` | pass | pass | pass | cancelled on FE, success on BE, same head |
| flaky | attempt 1 fails, attempt 2+ passes | pass | pass | pass | job_restarted via `make rerun` |
| slow | noise, sleep 180, pass | pass | pass | pass | long in_progress, status transitions |
| all-fail | exit 1 | exit 1 | exit 1 | exit 1 | multi-failure storm |
| broken-workflow | pass | pass | pass | pass | extra broken.yml run: failure with zero jobs |
| anything else | pass | pass | pass | pass | safe default |

## Event cookbook

| event | command |
|---|---|
| pr_discovered | `make pr-success` (or any `make pr-<scenario>`) |
| pr_head_changed | `make push PR=N` or `make scenario PR=N SCENARIO=x` |
| pr_merged | `make merge PR=N` |
| pr_closed / pr_reopened | `make close PR=N` / `make reopen PR=N` |
| pr_converted_to_draft / pr_ready_for_review | `make draft PR=N` / `make ready PR=N` |
| pr_review_submitted | `make review PR=N` |
| pr_review_comment (inline) | `make review-comment PR=N` |
| reply in an inline thread | `make reply PR=N COMMENT=<id>` |
| job_concluded(failure) | `make pr-fail-early` / `pr-fail-middle` / `pr-fail-late` |
| job killed by timeout (conclusion cancelled) | `make pr-timeout` |
| job_concluded(cancelled) | `make pr-cancel-me`, then `make cancel PR=N` |
| job_restarted | `make pr-flaky`, wait for red, then `make rerun PR=N` |
| zero-job broken run | `make pr-broken-workflow` |

Run `make help` for the full target list. Inspection helpers:
`make runs PR=N` (runs for the PR head SHA, the same drill the bot does),
`make jobs RUN=<id>`, `make log JOB=<id>`, `make watch PR=N`,
`make status`, `make cleanup`.

## Caveats

- Observed conclusions (2026-07): a job killed by `timeout-minutes`
  concludes `cancelled` (annotation: "The job has exceeded the maximum
  execution time"), not `timed_out`. The `broken-workflow` run concludes
  `failure`, not `startup_failure`. Both are in the usual failing sets,
  but exact-string assertions should use the observed values.
- The `broken-workflow` run contains zero jobs: a job-kind watcher sees
  nothing, you need workflow-kind watching (`--kind workflow`) to
  observe it.
- GitHub forbids approving your own PR, so `make review` defaults to
  `VERDICT=comment`. Approvals need a second account or token.
- Reopening a PR triggers a fresh pull_request run of the current
  scenario.
- `concurrency.cancel-in-progress: true` means a scenario-switch push
  cancels the superseded run, leaving cancelled conclusions on the old
  head. Realistic, but flip it to `false` if you need old runs to finish.
- The web UI truncates the display of 40k-line logs; the raw log from
  the API (`make log JOB=<id>`) is always complete.
- Merging a PR whose scenario is not `success` sets that scenario on
  main and turns the main branch run red. Merge success PRs, or fix
  `SCENARIO` on main afterwards. `make pr` always rewrites the file, so
  new PRs are unaffected either way.
- Log retention expires after 90 days; that is the only way to observe
  expired-log errors and it cannot be reproduced quickly.

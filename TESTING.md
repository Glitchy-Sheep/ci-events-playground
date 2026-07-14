# Testing playbook

Six sessions, each verifying one aspect of a watcher bot. Terminal 1
runs the bot, terminal 2 runs `make` commands from this repo.

## Setup

Terminal 1 (the bot; failurebot has its repo hardcoded, so ghwatch is
the easier demo):

```sh
cd ~/Sources/personal/git-github/github-build-robot
GITHUB_TOKEN=$(gh auth token) go run ./examples/ghwatch \
  --repo Glitchy-Sheep/ci-events-playground --user Glitchy-Sheep \
  --job 'glob:Build *' --interval 10s --fetch-logs --log-tail 30
```

Terminal 2: this repo. `make help` for targets, `make scenarios` for
the scenario matrix.

## Session 1: PR and job lifecycle

```sh
make pr-success        # expect: pr_discovered, job_discovered x5,
                       # queued->in_progress->completed, success x4 + Build Gate skipped
make push PR=<n>       # expect: pr_head_changed, then a fresh job set
make merge PR=<n>      # expect: pr_merged with MergedBy
```

## Session 2: errors in large logs (the core case)

```sh
make pr-fail-late                        # tail shows the real error: baseline
make scenario PR=<n> SCENARIO=fail-early # tail shows only runner cleanup noise
make scenario PR=<n> SCENARIO=fail-middle# panic buried at 50%
```

Compare what the bot printed against the truth:

```sh
make runs PR=<n>          # run ids for the head SHA
make jobs RUN=<id>        # find the failed Build FE job id
make log JOB=<id> | grep -nE "undefined:|panic:|--- FAIL"
```

Pass criterion: you can articulate what log-extraction strategy the
consumer needs beyond a tail. Try `--log-tail 0` (prints everything)
to feel why neither extreme works.

## Session 3: non-standard conclusions

```sh
make pr-timeout               # ~70s, conclusion cancelled + timeout annotation
make pr-cancel-me             # wait for Build FE in_progress (make watch PR=<n>)
make cancel PR=<n>            # mixed conclusions on one head: FE cancelled, BE success
make pr-flaky                 # red attempt 1
make rerun PR=<n>             # job_restarted, attempt 2 green
make pr-fail-multi            # FE+BE fail (matched), Unit Test fails too:
                              # the bot must stay silent about Unit Test
```

## Session 4: conversation events

Stock ghwatch/failurebot do NOT set EventFamilyPR, so reviews and
inline comments are invisible to them. Use a consumer with:

```go
Events: []ghbuildrobot.EventFamily{
    ghbuildrobot.EventFamilyJobs, ghbuildrobot.EventFamilyPR,
},
```

Then:

```sh
make comment PR=<n>                 # plain issue comment (no SDK event: control)
make review PR=<n>                  # pr_review_submitted (verdict comment)
make review-comment PR=<n>          # pr_review_comment; note the returned id
make reply PR=<n> COMMENT=<id>      # reply in thread: the hard detection case
make draft PR=<n> && make ready PR=<n>
make close PR=<n> && make reopen PR=<n>
```

## Session 5: kinds and edge cases

```sh
make pr-broken-workflow   # with --kind job the bot must stay silent (0 jobs);
                          # restart ghwatch with --kind workflow to see the failure run
make pr-dual-workflow     # two runs, both with a "Build FE" job, one green one red:
                          # does name matching confuse them?
make setup-env            # once
make pr-approval          # run hangs in waiting status: how does the bot render it?
make approve RUN=<id>     # gate runs and passes (or: make reject RUN=<id> -> failure)
make commit-status PR=<n> STATE=pending   # restart ghwatch with --kind status
make commit-status PR=<n> STATE=error     # KindStatus transitions, incl. state error
```

## Session 6: polling behavior and load

```sh
make storm N=5            # many PRs in one poll cycle: discovery, ETag reuse
make dispatch PR=<n>      # new run on the same head SHA without a push
make scenario PR=<n> SCENARIO=success && make scenario PR=<n> SCENARIO=fail-late
                          # rapid switches: concurrency cancels superseded runs
```

Watch the request economy with ghwatch `--rate` and compare `--no-rollup`
against the default GraphQL gate.

## Wrap up

```sh
make cleanup              # close all sbx/* PRs, delete branches
```

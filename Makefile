SHELL := /bin/bash
.DEFAULT_GOAL := help

NAME ?= ci-events-playground
STAMP := $(shell date +%y%m%d-%H%M%S)

# Lazy (= not :=): resolved only by targets that use them, they need PR=<n>.
HEADBRANCH = $(shell gh pr view $(PR) --json headRefName -q .headRefName)
HEADSHA = $(shell gh pr view $(PR) --json headRefOid -q .headRefOid)

NEED_PR = @[ -n "$(PR)" ] || { echo "usage: make $@ PR=<number> ..." >&2; exit 1; }

C_TITLE  := \033[1m
C_GROUP  := \033[1;33m
C_TARGET := \033[36m
C_VAR    := \033[33m
C_OK     := \033[32m
C_FAIL   := \033[31m
C_DIM    := \033[2m
C_END    := \033[0m

.PHONY: help scenarios init setup-env pr storm scenario dispatch push force-push \
	comment review review-comment reply draft ready close reopen merge \
	cancel rerun rerun-all approve reject commit-status \
	runs jobs log watch status open cleanup

##@ 📖 Meta

help: ## Show this help
	@printf "\n$(C_TITLE)ci-events-playground$(C_END) - fire GitHub PR/CI events with make + gh\n"
	@printf "\nUsage: make $(C_TARGET)<target>$(C_END) $(C_VAR)[VAR=value ...]$(C_END)\n"
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n$(C_GROUP)%s$(C_END)\n", substr($$0, 5); next } \
		/^[a-zA-Z%_-]+:.*?##/ { printf "  $(C_TARGET)%-16s$(C_END) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n$(C_DIM)Scenario names: make scenarios. Typical session: make pr-fail-middle,\n"
	@printf "watch the bot, make merge PR=<n>, make cleanup.$(C_END)\n\n"

scenarios: ## Describe every scenario and its expected outcome
	@printf "\n$(C_TITLE)Scenarios$(C_END)  $(C_DIM)make pr-<name> / make scenario PR=<n> SCENARIO=<name>$(C_END)\n\n"
	@printf "  $(C_OK)success$(C_END)          all jobs green (Build Gate skipped); baseline job events\n"
	@printf "  $(C_FAIL)fail-early$(C_END)       Build FE: 40k-line log, compile error at ~2%%; tail printing misses it\n"
	@printf "  $(C_FAIL)fail-middle$(C_END)      Build FE: 40k-line log, panic at ~50%%\n"
	@printf "  $(C_FAIL)fail-late$(C_END)        Build FE: 40k-line log, test failure at the end; tail printing works\n"
	@printf "  $(C_FAIL)fail-multi$(C_END)       Build FE + Build BE + Unit Test fail (short logs); Lint green\n"
	@printf "  $(C_FAIL)timeout$(C_END)          Build FE killed by timeout-minutes 1: conclusion cancelled, ~60-70s\n"
	@printf "  $(C_FAIL)cancel-me$(C_END)        Build FE sleeps 30 min; run 'make cancel PR=<n>' for mixed conclusions\n"
	@printf "  $(C_FAIL)flaky$(C_END)            Build FE fails attempt 1, passes after 'make rerun PR=<n>' (job_restarted)\n"
	@printf "  $(C_OK)slow$(C_END)             Build FE sleeps 3 min mid-log: long in_progress phase\n"
	@printf "  $(C_FAIL)all-fail$(C_END)         every job exits 1: multi-failure storm\n"
	@printf "  $(C_FAIL)broken-workflow$(C_END)  extra zero-job run, conclusion failure; needs workflow-kind watching\n"
	@printf "  $(C_FAIL)dual-workflow$(C_END)    second run with a clashing 'Build FE' job name that fails\n"
	@printf "  $(C_VAR)approval$(C_END)         Build Gate waits on the approval-gate environment;\n"
	@printf "                   'make approve RUN=<id>' / 'make reject RUN=<id>' (once: make setup-env)\n"
	@printf "\n  Build Gate is skipped in all non-approval scenarios: skipped-conclusion coverage.\n"
	@printf "  Not reproducible here: timed_out and neutral/action_required conclusions,\n"
	@printf "  check runs (KindCheck) - they need a GitHub App or a second account.\n\n"

##@ ⚙️  Setup

init: ## One-time: create the public GitHub repo from this directory and push main
	git init -b main 2>/dev/null || true
	git add -A
	git commit -m "Initial playground setup"
	gh repo create $(NAME) --public --source=. --remote=origin --push

setup-env: ## One-time: approval-gate environment with yourself as required reviewer
	@uid=$$(gh api user --jq .id); \
	printf '{"reviewers":[{"type":"User","id":%s}]}' "$$uid" | \
	gh api -X PUT repos/{owner}/{repo}/environments/approval-gate --input - \
		--jq '"environment " + .name + " configured"'

##@ 🚀 Scenario PRs

pr: ## Open a PR: SCENARIO=<name> [DRAFT=1]
	@[ -n "$(SCENARIO)" ] || { echo "usage: make pr SCENARIO=<name> [DRAFT=1]" >&2; exit 1; }
	git checkout main && git pull --ff-only
	git checkout -b sbx/$(SCENARIO)-$(STAMP)
	./scripts/apply-scenario.sh $(SCENARIO) $(STAMP)
	git commit -m "scenario: $(SCENARIO)"
	git push -u origin HEAD
	gh pr create --title "sbx: $(SCENARIO) $(STAMP)" --body "Scenario: $(SCENARIO)" $(if $(DRAFT),--draft)
	git checkout main

pr-%: ## Shorthand: make pr-fail-early == make pr SCENARIO=fail-early
	@$(MAKE) pr SCENARIO=$*

storm: ## Open several PRs at once (discovery load): [N=3] [SCENARIO=success]
	@for i in $$(seq 1 $(or $(N),3)); do \
		$(MAKE) pr SCENARIO=$(or $(SCENARIO),success) || exit 1; sleep 1; \
	done

scenario: ## Switch scenario on a live PR (also a head change): PR=<n> SCENARIO=<name>
	$(NEED_PR)
	@[ -n "$(SCENARIO)" ] || { echo "usage: make scenario PR=<n> SCENARIO=<name>" >&2; exit 1; }
	gh pr checkout $(PR)
	./scripts/apply-scenario.sh $(SCENARIO) $(STAMP)
	git commit -m "switch scenario: $(SCENARIO)"
	git push
	git checkout main

dispatch: ## Re-run CI on the PR branch without a push: PR=<n> [SCENARIO=<name>]
	$(NEED_PR)
	gh workflow run ci.yml --ref "$(HEADBRANCH)" $(if $(SCENARIO),-f scenario=$(SCENARIO))

##@ 🔀 Head changes

push: ## Push a ping commit to the PR branch (pr_head_changed): PR=<n>
	$(NEED_PR)
	gh pr checkout $(PR)
	date -u >> PING
	git commit -am "ping $(STAMP)"
	git push
	git checkout main

force-push: ## Amend + force-push: new head SHA, no new commit: PR=<n>
	$(NEED_PR)
	gh pr checkout $(PR)
	git commit --amend --no-edit
	git push -f
	git checkout main

##@ 💬 Conversation

comment: ## Plain issue comment: PR=<n> [BODY=text]
	$(NEED_PR)
	gh pr comment $(PR) --body "$(or $(BODY),ping from Makefile at $(STAMP))"

review: ## Submit a review (pr_review_submitted): PR=<n> [VERDICT=comment|approve|request-changes] [BODY=text]
	$(NEED_PR)
	gh pr review $(PR) --$(or $(VERDICT),comment) --body "$(or $(BODY),review ping $(STAMP))"

# Default LINE=2: the stamp line of SCENARIO is always an added line in the diff.
review-comment: ## Inline review comment (pr_review_comment): PR=<n> [FILE=SCENARIO] [LINE=2] [BODY=text]
	$(NEED_PR)
	gh api repos/{owner}/{repo}/pulls/$(PR)/comments \
		-f body="$(or $(BODY),inline ping $(STAMP))" \
		-f commit_id="$(HEADSHA)" \
		-f path="$(or $(FILE),SCENARIO)" \
		-F line=$(or $(LINE),2) \
		-f side=RIGHT

reply: ## Reply in an inline thread (hardest detection case): PR=<n> COMMENT=<comment-id> [BODY=text]
	$(NEED_PR)
	@[ -n "$(COMMENT)" ] || { echo "usage: make reply PR=<n> COMMENT=<comment-id>" >&2; exit 1; }
	gh api repos/{owner}/{repo}/pulls/$(PR)/comments/$(COMMENT)/replies \
		-f body="$(or $(BODY),reply ping $(STAMP))"

##@ 📦 PR lifecycle

draft: ## Convert PR to draft (pr_converted_to_draft): PR=<n>
	$(NEED_PR)
	gh pr ready $(PR) --undo

ready: ## Mark PR ready for review (pr_ready_for_review): PR=<n>
	$(NEED_PR)
	gh pr ready $(PR)

close: ## Close PR without merging (pr_closed): PR=<n>
	$(NEED_PR)
	gh pr close $(PR)

reopen: ## Reopen a closed PR (pr_reopened): PR=<n>
	$(NEED_PR)
	gh pr reopen $(PR)

merge: ## Squash-merge PR (pr_merged): PR=<n>. Non-success scenarios turn main red.
	$(NEED_PR)
	gh pr merge $(PR) --squash --delete-branch

##@ 🔁 Run control

cancel: ## Cancel the active run of the PR branch (conclusion cancelled): PR=<n>
	$(NEED_PR)
	@id=$$(gh run list --branch "$(HEADBRANCH)" --json databaseId,status \
		--jq '[.[] | select(.status=="in_progress" or .status=="queued")][0].databaseId'); \
	[ -n "$$id" ] && [ "$$id" != "null" ] || { echo "no active run on $(HEADBRANCH)" >&2; exit 1; }; \
	echo "cancelling run $$id"; gh run cancel $$id

rerun: ## Rerun failed jobs of the last failed run (job_restarted): PR=<n>
	$(NEED_PR)
	@id=$$(gh run list --branch "$(HEADBRANCH)" --status failure --limit 1 \
		--json databaseId --jq '.[0].databaseId'); \
	[ -n "$$id" ] && [ "$$id" != "null" ] || { echo "no failed run on $(HEADBRANCH)" >&2; exit 1; }; \
	echo "rerunning failed jobs of run $$id"; gh run rerun $$id --failed

rerun-all: ## Rerun all jobs of a run: RUN=<run-id>
	@[ -n "$(RUN)" ] || { echo "usage: make rerun-all RUN=<run-id>" >&2; exit 1; }
	gh run rerun $(RUN)

approve: ## Approve the waiting approval-gate deployment: RUN=<run-id>
	@[ -n "$(RUN)" ] || { echo "usage: make approve RUN=<run-id>" >&2; exit 1; }
	@envid=$$(gh api repos/{owner}/{repo}/environments/approval-gate --jq .id); \
	gh api -X POST repos/{owner}/{repo}/actions/runs/$(RUN)/pending_deployments \
		-F "environment_ids[]=$$envid" -f state=approved -f comment="approved from Makefile" \
		--jq '.[].environment + ": approved"'

reject: ## Reject the waiting approval-gate deployment: RUN=<run-id>
	@[ -n "$(RUN)" ] || { echo "usage: make reject RUN=<run-id>" >&2; exit 1; }
	@envid=$$(gh api repos/{owner}/{repo}/environments/approval-gate --jq .id); \
	gh api -X POST repos/{owner}/{repo}/actions/runs/$(RUN)/pending_deployments \
		-F "environment_ids[]=$$envid" -f state=rejected -f comment="rejected from Makefile" \
		--jq '.[].environment + ": rejected"'

##@ 🌐 External status (KindStatus)

commit-status: ## Set a legacy commit status on the PR head: PR=<n> STATE=pending|success|failure|error [CONTEXT=external-ci] [DESC=text]
	$(NEED_PR)
	@[ -n "$(STATE)" ] || { echo "usage: make commit-status PR=<n> STATE=pending|success|failure|error" >&2; exit 1; }
	gh api repos/{owner}/{repo}/statuses/$(HEADSHA) \
		-f state=$(STATE) \
		-f context="$(or $(CONTEXT),external-ci)" \
		-f description="$(or $(DESC),playground status $(STAMP))" \
		--jq '.context + ": " + .state'

##@ 🔍 Inspect

runs: ## List runs for the PR head SHA (mirrors the bot's drill): PR=<n>
	$(NEED_PR)
	gh run list --commit "$(HEADSHA)" \
		--json databaseId,workflowName,event,status,conclusion,attempt

jobs: ## Show job conclusions of a run: RUN=<run-id>
	@[ -n "$(RUN)" ] || { echo "usage: make jobs RUN=<run-id>" >&2; exit 1; }
	gh run view $(RUN) --json jobs --jq '.jobs[] | {name, status, conclusion}'

log: ## Download the raw log of a job: JOB=<job-id>
	@[ -n "$(JOB)" ] || { echo "usage: make log JOB=<job-id>" >&2; exit 1; }
	gh api repos/{owner}/{repo}/actions/jobs/$(JOB)/logs

watch: ## Watch the latest run of the PR branch: PR=<n>
	$(NEED_PR)
	gh run watch $$(gh run list --branch "$(HEADBRANCH)" --limit 1 \
		--json databaseId --jq '.[0].databaseId')

status: ## My open PRs and recent runs
	gh pr list --author "@me"
	gh run list --limit 15

open: ## Open PR in browser: PR=<n>
	$(NEED_PR)
	gh pr view $(PR) --web

##@ 🧹 Cleanup

cleanup: ## Close all sbx/* PRs and delete their branches
	@for n in $$(gh pr list --json number,headRefName \
		--jq '.[] | select(.headRefName | startswith("sbx/")) | .number'); do \
		echo "closing PR #$$n"; gh pr close $$n --delete-branch; \
	done
	@git checkout main >/dev/null 2>&1 || true
	@git fetch -p origin
	@for b in $$(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/sbx/*' | sed 's|^origin/||'); do \
		echo "deleting remote branch $$b"; git push origin --delete "$$b" || true; \
	done
	@locals=$$(git for-each-ref --format='%(refname:short)' 'refs/heads/sbx/*'); \
	[ -z "$$locals" ] || git branch -D $$locals

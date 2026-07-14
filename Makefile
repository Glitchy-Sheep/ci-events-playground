SHELL := /bin/bash
.DEFAULT_GOAL := help

NAME ?= ci-events-playground
STAMP := $(shell date +%y%m%d-%H%M%S)

# Lazy (= not :=): resolved only by targets that use them, they need PR=<n>.
HEADBRANCH = $(shell gh pr view $(PR) --json headRefName -q .headRefName)
HEADSHA = $(shell gh pr view $(PR) --json headRefOid -q .headRefOid)

NEED_PR = @[ -n "$(PR)" ] || { echo "usage: make $@ PR=<number> ..." >&2; exit 1; }

.PHONY: help init pr push scenario comment review review-comment reply draft ready \
	close reopen merge cancel rerun rerun-all dispatch runs jobs log watch status open cleanup

help: ## Show this help
	@grep -hE '^[a-zA-Z%_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

init: ## One-time: create the public GitHub repo from this directory and push main
	git init -b main 2>/dev/null || true
	git add -A
	git commit -m "Initial playground setup"
	gh repo create $(NAME) --public --source=. --remote=origin --push

pr: ## Open a PR: SCENARIO=<name> [DRAFT=1]
	@[ -n "$(SCENARIO)" ] || { echo "usage: make pr SCENARIO=<name> [DRAFT=1]" >&2; exit 1; }
	git checkout main && git pull --ff-only
	git checkout -b sbx/$(SCENARIO)-$(STAMP)
	echo $(SCENARIO) > SCENARIO
	@if [ "$(SCENARIO)" = "broken-workflow" ]; then \
		cp broken/invalid-workflow.yml .github/workflows/broken.yml; \
		git add .github/workflows/broken.yml; \
	fi
	git commit -am "scenario: $(SCENARIO)"
	git push -u origin HEAD
	gh pr create --title "sbx: $(SCENARIO) $(STAMP)" --body "Scenario: $(SCENARIO)" $(if $(DRAFT),--draft)
	git checkout main

pr-%: ## Shorthand: make pr-fail-early == make pr SCENARIO=fail-early
	@$(MAKE) pr SCENARIO=$*

push: ## Push a no-op commit to the PR branch (pr_head_changed): PR=<n>
	$(NEED_PR)
	gh pr checkout $(PR)
	date -u >> PING
	git commit -am "ping $(STAMP)"
	git push
	git checkout main

scenario: ## Switch scenario on an existing PR: PR=<n> SCENARIO=<name>
	$(NEED_PR)
	@[ -n "$(SCENARIO)" ] || { echo "usage: make scenario PR=<n> SCENARIO=<name>" >&2; exit 1; }
	gh pr checkout $(PR)
	echo $(SCENARIO) > SCENARIO
	@if [ "$(SCENARIO)" = "broken-workflow" ]; then \
		cp broken/invalid-workflow.yml .github/workflows/broken.yml; \
		git add .github/workflows/broken.yml; \
	elif [ -f .github/workflows/broken.yml ]; then \
		git rm -q .github/workflows/broken.yml; \
	fi
	git commit -am "switch scenario: $(SCENARIO)"
	git push
	git checkout main

comment: ## Plain issue comment: PR=<n> [BODY=text]
	$(NEED_PR)
	gh pr comment $(PR) --body "$(or $(BODY),ping from Makefile at $(STAMP))"

review: ## Submit a review (pr_review_submitted): PR=<n> [VERDICT=comment|approve|request-changes] [BODY=text]
	$(NEED_PR)
	gh pr review $(PR) --$(or $(VERDICT),comment) --body "$(or $(BODY),review ping $(STAMP))"

review-comment: ## Inline review comment (pr_review_comment): PR=<n> [FILE=SCENARIO] [LINE=1] [BODY=text]
	$(NEED_PR)
	gh api repos/{owner}/{repo}/pulls/$(PR)/comments \
		-f body="$(or $(BODY),inline ping $(STAMP))" \
		-f commit_id="$(HEADSHA)" \
		-f path="$(or $(FILE),SCENARIO)" \
		-F line=$(or $(LINE),1) \
		-f side=RIGHT

reply: ## Reply in an inline thread (hardest detection case): PR=<n> COMMENT=<comment-id> [BODY=text]
	$(NEED_PR)
	@[ -n "$(COMMENT)" ] || { echo "usage: make reply PR=<n> COMMENT=<comment-id>" >&2; exit 1; }
	gh api repos/{owner}/{repo}/pulls/$(PR)/comments/$(COMMENT)/replies \
		-f body="$(or $(BODY),reply ping $(STAMP))"

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

merge: ## Squash-merge PR (pr_merged): PR=<n>. Merging a non-success scenario turns main red.
	$(NEED_PR)
	gh pr merge $(PR) --squash --delete-branch

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

dispatch: ## Re-trigger CI on the PR branch without a push: PR=<n> [SCENARIO=<name>]
	$(NEED_PR)
	gh workflow run ci.yml --ref "$(HEADBRANCH)" $(if $(SCENARIO),-f scenario=$(SCENARIO))

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

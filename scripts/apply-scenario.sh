#!/usr/bin/env bash
# Write the SCENARIO file and sync scenario-specific extra workflows.
# Stages everything it touches; the caller commits.
#
# Usage: apply-scenario.sh <scenario> <stamp>
set -euo pipefail

SCENARIO="${1:?usage: apply-scenario.sh <scenario> <stamp>}"
STAMP="${2:?usage: apply-scenario.sh <scenario> <stamp>}"

# Line 1 is the scenario name (read by the Prep job), line 2 a stamp
# so every scenario change has a non-empty diff.
printf '%s\nstamp: %s\n' "$SCENARIO" "$STAMP" > SCENARIO
git add SCENARIO

# The extra workflow is present only while its scenario is active.
sync_extra() { # <owning-scenario> <source> <dest>
  if [ "$SCENARIO" = "$1" ]; then
    cp "$2" "$3"
    git add "$3"
  elif [ -f "$3" ]; then
    git rm -q "$3"
  fi
}
sync_extra broken-workflow extra/broken-workflow.yml .github/workflows/broken.yml
sync_extra dual-workflow extra/dual-workflow.yml .github/workflows/dual.yml

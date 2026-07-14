#!/usr/bin/env bash
# Per-job scenario dispatcher. Owns all exit codes and sleeps.
#
# Usage: run-scenario.sh <role> <scenario>
# Roles: fe (Build FE), be (Build BE), lint (Lint), test (Unit Test).
# Unknown scenarios and unlisted role combinations pass.
set -euo pipefail

ROLE="${1:?usage: run-scenario.sh <role> <scenario>}"
SCENARIO="${2:-success}"
NOISE="$(dirname "$0")/lognoise.sh"
LINES="${LOG_LINES:-40000}"

echo "scenario=$SCENARIO role=$ROLE attempt=${GITHUB_RUN_ATTEMPT:-local}"

pass() {
  "$NOISE" --lines "${1:-120}" --error-at none
  echo "RESULT: ok (role=$ROLE scenario=$SCENARIO)"
  exit 0
}

fail_with_log() { # <error-at> <error-kind> [lines]
  "$NOISE" --lines "${3:-$LINES}" --error-at "$1" --error-kind "$2"
  echo "RESULT: failed (role=$ROLE scenario=$SCENARIO)"
  exit 1
}

case "$SCENARIO:$ROLE" in
  fail-early:fe)   fail_with_log start compile ;;
  fail-middle:fe)  fail_with_log middle panic ;;
  fail-late:fe)    fail_with_log end test ;;

  fail-multi:fe)   fail_with_log middle compile 300 ;;
  fail-multi:be)   fail_with_log middle panic 300 ;;
  fail-multi:test) fail_with_log end test 300 ;;

  # Job-level timeout-minutes (1) kills the job. GitHub reports
  # conclusion cancelled with a max-execution-time annotation.
  timeout:fe)
    "$NOISE" --lines 200 --error-at none
    echo "sleeping until timeout-minutes kills the job"
    sleep 300
    ;;

  # Long sleep so 'make cancel PR=<n>' can hit an in_progress run.
  cancel-me:fe)
    "$NOISE" --lines 200 --error-at none
    echo "sleeping; cancel this run with: make cancel PR=<n>"
    sleep 1800
    ;;

  flaky:fe)
    if [ "${GITHUB_RUN_ATTEMPT:-1}" = "1" ]; then
      fail_with_log end test 400
    fi
    pass
    ;;

  # Long in_progress phase for observing status transitions.
  slow:fe)
    "$NOISE" --lines 200 --error-at none
    sleep 180
    pass 200
    ;;

  all-fail:*)      fail_with_log end "$([ "$ROLE" = fe ] && echo panic || echo test)" 300 ;;

  *) pass ;;
esac

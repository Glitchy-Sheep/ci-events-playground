#!/usr/bin/env bash
# Резолвер ID рана Actions для Taskfile: печатает ID в stdout.
# - с непустым первым аргументом: возвращает его как есть (явный RUN=<id>)
# - режим waiting: последний ран в статусе waiting (approval-gate)
# - режим latest [ветка]: последний ран ветки; без ветки берется ветка
#   последнего открытого sbx-PR (через find-pr.sh)
# Если кандидата нет - подсказка в stderr и exit 1.
#
# Usage: find-run.sh [явный-ID] <waiting|latest> [ветка]
set -euo pipefail

explicit="${1:-}"
mode="${2:?usage: find-run.sh [id] <waiting|latest> [branch]}"

if [ -n "$explicit" ]; then
  echo "$explicit"
  exit 0
fi

case "$mode" in
  waiting)
    run="$(gh run list --status waiting --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty')"
    hint="Нет рана, ожидающего одобрения (waiting), а RUN=<id> не указан.
Сначала: task pr-approval (одноразово перед этим: task setup-env)."
    ;;
  latest)
    branch="${3:-}"
    if [ -z "$branch" ]; then
      pr="$("$(dirname "$0")/find-pr.sh" "")"
      branch="$(gh pr view "$pr" --json headRefName -q .headRefName)"
    fi
    run="$(gh run list --branch "$branch" --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty')"
    hint="На ветке $branch нет ранов CI."
    ;;
  *)
    echo "find-run.sh: неизвестный режим '$mode'" >&2
    exit 1
    ;;
esac

if [ -z "$run" ]; then
  echo "$hint" >&2
  exit 1
fi
echo "$run"

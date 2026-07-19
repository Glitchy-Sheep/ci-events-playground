#!/usr/bin/env bash
# Резолвер номера PR для Taskfile: печатает номер в stdout.
# - с непустым первым аргументом: возвращает его как есть (явный PR=<n>)
# - режим open (дефолт): последний открытый PR с веткой sbx/*
# - режим closed: последний закрытый (не влитый) sbx-PR - для task reopen
# Если кандидата нет - подсказка в stderr и exit 1.
#
# Usage: find-pr.sh [явный-номер] [open|closed]
set -euo pipefail

explicit="${1:-}"
state="${2:-open}"

if [ -n "$explicit" ]; then
  echo "$explicit"
  exit 0
fi

case "$state" in
  open)
    pr="$(gh pr list --author "@me" --json number,headRefName \
      --jq '[.[] | select(.headRefName | startswith("sbx/"))][0].number // empty')"
    hint="Не нашел открытых sbx-PR, а PR=<n> не указан.
Открой сценарный PR: task pr (успешный) или, например, task pr-fail-late.
Список сценариев: task scenarios. Открытые PR: task status."
    ;;
  closed)
    pr="$(gh pr list --state closed --author "@me" --json number,headRefName,state \
      --jq '[.[] | select((.headRefName | startswith("sbx/")) and .state == "CLOSED")][0].number // empty')"
    hint="Не нашел закрытых sbx-PR для переоткрытия. Сначала закрой: task close."
    ;;
  *)
    echo "find-pr.sh: неизвестный режим '$state'" >&2
    exit 1
    ;;
esac

if [ -z "$pr" ]; then
  echo "$hint" >&2
  exit 1
fi
echo "$pr"

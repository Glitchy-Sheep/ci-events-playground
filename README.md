# ci-events-playground

Ручной полигон для ботов, следящих за CI (построен для Go SDK
[ghbuildrobot](https://github.com/Glitchy-Sheep), но подходит любому
боту, который поллит PR-ы и GitHub Actions). Любое событие жизненного
цикла PR и любое падающее заключение джобы - одна команда `task`,
внутри только `gh` и `git`.

Репозиторий публичный намеренно: GitHub-hosted раннеры Actions
бесплатны в публичных репо, а draft-PR недоступны в приватных репо на
бесплатном плане.

## Установка

```sh
gh auth login          # один раз
task init              # один раз: создает репозиторий на GitHub и пушит main
```

Дальше наведи на репозиторий бота. Основной потребитель -
telegram-pr-watcher (полный плейбук в TESTING.md: локальный запуск
бота, подписки в Telegram, ожидания по каждому сценарию). Для сырого
вывода SDK без Telegram есть ghwatch:

```sh
go run ./examples/ghwatch \
  --repo Glitchy-Sheep/ci-events-playground --user Glitchy-Sheep \
  --job 'glob:Build *' --interval 10s --fetch-logs
```

## Как устроены сценарии

Файл `SCENARIO` в корне выбирает поведение CI: строка 1 - имя сценария,
строка 2 - timestamp, чтобы у каждого сценарного PR был непустой diff
(и гарантированный якорь для inline-комментария). `task pr` открывает
PR, ветка которого задает этот файл; сценарий по умолчанию `success`,
другой задается шорткатом `task pr-fail-late` (то же, что
`task pr SCENARIO=fail-late`). Джоба `Prep` читает файл и раздает
поведение пяти джобам со стабильными именами: `Build FE` (матчится
`ExactJob("Build FE")` и глобом `Build *`), `Build BE` (только глоб),
`Build Gate` (глоб; skipped везде, кроме сценария `approval`, так что
каждый ран несет и заключение skipped), `Lint` и `Unit Test`
(не матчатся никогда, контрольные джобы). Сценарий на живом PR меняется
через `task scenario SCENARIO=<имя>` (пуш заодно дает событие смены
head), перезапуск CI без пуша - `task dispatch [SCENARIO=<имя>]`.

Почти везде `PR=<n>` и `RUN=<id>` указывать не обязательно: команда
сама возьмет последний открытый sbx-PR (а `task approve`/`task reject` -
ран в статусе waiting) и напишет, какой взяла. Явные `PR=42`/`RUN=<id>`
продолжают работать.

## Матрица сценариев

| сценарий | Build FE | Build BE | Lint | Unit Test | что проверяет |
|---|---|---|---|---|---|
| success | ок | ок | ок | ок | job_discovered, job_concluded(success) |
| fail-early | 40k строк, ошибки компиляции на ~2%, exit 1 | ок | ок | ок | выкачивание полного лога; tail-печать ошибку НЕ видит |
| fail-middle | 40k строк, panic на ~50%, exit 1 | ок | ок | ок | то же, середина |
| fail-late | 40k строк, падение теста в конце, exit 1 | ок | ок | ок | здесь tail-печать работает |
| fail-multi | 300 строк, exit 1 | 300 строк, exit 1 | ок | 300 строк, exit 1 | два матчащихся падения плюс одно нематчащееся (бот должен о нем молчать) |
| timeout | sleep 300, убит timeout-minutes 1 | ок | ок | ок | conclusion cancelled с аннотацией про таймаут, ~60-70 с |
| cancel-me | sleep 1800 до `task cancel` | ок | ок | ок | cancelled на FE, success на BE, один head |
| flaky | попытка 1 падает, 2+ проходит | ок | ок | ок | job_restarted через `task rerun` |
| slow | шум, sleep 180, ок | ок | ок | ок | долгий in_progress, переходы статусов |
| all-fail | exit 1 | exit 1 | exit 1 | exit 1 | шторм падений |
| broken-workflow | ок | ок | ок | ок | лишний ран broken.yml: failure с нулем джоб |
| dual-workflow | ок | ок | ок | ок | лишний ран dual.yml со вторым, падающим "Build FE": коллизия имен джоб на одном head |
| approval | ок | ок | ок | ок | Build Gate держит ран в статусе waiting до `task approve` / `task reject` |
| что угодно еще | ок | ок | ок | ок | безопасный дефолт |

Сценарию `approval` нужен одноразовый `task setup-env` (создает
environment `approval-gate` с тобой как обязательным ревьюером); без
него джоба-гейт стартует сразу. Наблюдалось: `task approve` дает гейту
отработать и пройти; `task reject` завершает джобу-гейт (и весь ран)
как `failure`.

## Шпаргалка по событиям

| событие | команда |
|---|---|
| pr_discovered | `task pr-success` (или любой `task pr-<сценарий>`); `task storm N=5` для пачки сразу |
| pr_head_changed | `task push`, `task force-push` или `task scenario SCENARIO=x` |
| pr_merged | `task merge` |
| pr_closed / pr_reopened | `task close` / `task reopen` |
| pr_converted_to_draft / pr_ready_for_review | `task draft` / `task ready` |
| pr_review_submitted | `task review` |
| pr_review_comment (inline) | `task review-comment` |
| ответ в inline-треде | `task reply COMMENT=<id>` |
| job_concluded(failure) | `task pr-fail-early` / `pr-fail-middle` / `pr-fail-late` |
| джоба убита таймаутом (conclusion cancelled) | `task pr-timeout` |
| job_concluded(cancelled) | `task pr-cancel-me`, затем `task cancel` |
| job_restarted | `task pr-flaky`, дождаться красного, затем `task rerun` |
| job_concluded(skipped) | любой сценарий: Build Gate skipped вне `approval` |
| ран в waiting + deployment review | `task pr-approval`, затем `task approve` или `task reject` |
| ран без единой джобы | `task pr-broken-workflow` |
| коллизия имен джоб на одном head | `task pr-dual-workflow` |
| KindStatus (commit statuses, включая state `error`) | `task commit-status STATE=pending`, затем `STATE=success`/`failure`/`error` |

`task` без аргументов - справка со всеми командами и типичной сессией,
`task scenarios` - разбор каждого сценария, `task guide` - пошаговый
план e2e-теста telegram-pr-watcher. Инспекция: `task runs`
(раны на head SHA PR, тот же запрос, что делает бот), `task jobs`,
`task log JOB=<id>`, `task watch`, `task status`. Уборка:
`task cleanup`.

## Грабли

- Наблюдаемые заключения (2026-07): джоба, убитая `timeout-minutes`,
  завершается `cancelled` (аннотация "The job has exceeded the maximum
  execution time"), а не `timed_out`. Ран `broken-workflow` завершается
  `failure`, а не `startup_failure`. Оба входят в обычные "падающие"
  наборы, но точные строковые сравнения должны использовать наблюдаемые
  значения.
- В ране `broken-workflow` ноль джоб: watcher уровня джоб не видит
  ничего, наблюдать его можно только watcher-ом уровня workflow
  (`--kind workflow`).
- GitHub запрещает одобрять свой же PR, поэтому `task review` по
  умолчанию шлет `VERDICT=comment`. Для approve нужен второй аккаунт
  или другой токен.
- Переоткрытие PR запускает свежий pull_request-ран текущего сценария.
- `concurrency.cancel-in-progress: true`: пуш со сменой сценария
  отменяет вытесненный ран, оставляя cancelled-заключения на старом
  head. Это реалистично, но поставь `false`, если старые раны должны
  дорабатывать до конца.
- Веб-интерфейс обрезает отображение 40k-строчных логов; сырой лог из
  API (`task log JOB=<id>`) всегда полный.
- Мерж PR со сценарием, отличным от `success`, записывает этот сценарий
  в main и красит ран main в красный. Мержи success-PR или почини файл
  `SCENARIO` на main после. `task pr` всегда перезаписывает файл, так
  что новые PR не страдают в любом случае.
- Логи хранятся 90 дней; истечение - единственный способ увидеть
  ошибку expired-log, быстро не воспроизводится.

## Что здесь не воспроизвести

- Check runs (KindCheck) и заключение `neutral`: check runs создают
  только GitHub Apps. Ближайшая замена - commit statuses
  (`task commit-status`), они покрывают KindStatus.
- `timed_out`: джоба, убитая `timeout-minutes`, завершается `cancelled`
  (см. выше). Строка `timed_out` остается непротестированной.
- `action_required`: нужен PR первого контрибьютора из форка, то есть
  второй аккаунт или форк организации.
- `stale`: GitHub порождает его внутренними механизмами, снаружи не
  вызывается.

# Плейбук тестирования telegram-pr-watcher

Полигон дергает события GitHub, бот доставляет их в Telegram. Терминал 1
запускает бота, терминал 2 - команды make из этого репо, телефон/десктоп
Telegram - наблюдение и управление подписками.

Бот построен на ghbuildrobot, поэтому каждая строка матрицы сценариев
(`make scenarios`) имеет смысл и для него. Ожидаемые сообщения ниже
описаны по фактическим рендерам бота (internal/render).

## Подготовка

### Отдельный тестовый бот - обязательно

Прод-инстанс уже long-poll-ит прод-токен; второй процесс с тем же
токеном получит 409 Conflict и будет красть апдейты. Создай у BotFather
отдельного тестового бота и используй его токен локально.

### .env для тестового запуска

```sh
cd ~/Sources/personal/git-github/telegram-pr-watcher
# в .env (не трогая prod.env):
# TELEGRAM_BOT_TOKEN=<токен тестового бота от BotFather>
# GITHUB_TOKEN=<gh auth token>   # repo-scope: кнопка rerun будет работать
# TELEGRAM_ADMIN_IDS=<твой telegram id>
# TELEGRAM_SUPPORT_IDS=<твой telegram id>
# POLL_INTERVAL=5s               # минимум SDK; для живых тестов самое то
# DB_PATH=./data/test.db         # не трогаем дев-базу data/prwatcher.db
task run
```

Чистый прогон = удалить `data/test.db` перед стартом. Не подкладывай
существующую базу с подписками под пустой sdk_dedup: бот выдаст лавину
"новых" событий по всему бэклогу.

### Подписки в Telegram

`/start`, дальше два пути:
- `/subscribe` - визард: автор `Glitchy-Sheep`, репо
  `ci-events-playground`, вид 🔧 jobs со спеками (`glob:Build *`
  покрывает Build FE/BE/Gate) и/или 📋 PR-статус;
- вставить URL PR (или `Glitchy-Sheep/ci-events-playground#N`) - точечная
  подписка на один PR.

Сразу после подписки бот шлет снапшот текущего состояния - это уже
первый тест (U-01: большой снапшот не должен ломать сохранение).

## Сессия 1: джобы и supersede

```sh
make pr-success
```

Ожидания в Telegram: цепочка "в очереди" -> "выполняется" -> ✅ по
каждой матчащейся джобе. Каждое новое состояние приходит НОВЫМ
сообщением, а предыдущее сообщение той же джобы удаляется (supersede) -
если включена очистка устаревших в `/settings`. Проверь оба положения
настройки. Build Gate придет как skipped-заключение.

```sh
make push PR=<n>     # свежий head: новый набор джоб поверх старых
make merge PR=<n>    # если есть 📋: "влит" + подписка на PR уходит из /subscriptions
```

## Сессия 2: хвост лога при падениях - главная

```sh
make pr-fail-late                          # ошибка в конце 40k-строчного лога
make scenario PR=<n> SCENARIO=fail-early   # ошибка в начале
make scenario PR=<n> SCENARIO=fail-middle  # panic в середине
```

Бот берет последние 30 строк лога в раскрываемый blockquote, бюджет
сообщения 4000 рун, строки с error/fail/panic подсвечиваются 🔴.

- fail-late: ошибка ВИДНА в хвосте, 🔴 на строках FAIL - эталон.
- fail-early / fail-middle: хвост состоит из шума, ошибки в сообщении
  НЕТ вообще. Это известное ограничение tail-стратегии - именно тот
  материал, ради которого полигон строился. Сравни с правдой:
  `make jobs RUN=<id>`, `make log JOB=<id> | grep -nE "panic:|undefined:"`.
- Проверь маркировку "…(обрезано)" и заголовок "Хвост лога · обрезано".

## Сессия 3: кнопка rerun и перезапуски

```sh
make pr-flaky        # attempt 1 падает
```

В сообщении о падении есть кнопка перезапуска: тапни ее (нужен
GITHUB_TOKEN с правом actions:write - `gh auth token` с repo-скоупом
подходит). Ожидания: быстрый ack на тап (U-04), затем "перезапущена"
(job_restarted, с прошлой попыткой), затем ✅ attempt 2. Альтернатива из
терминала: `make rerun PR=<n>`. Отдельно проверь путь с read-only
токеном: кнопка должна честно сказать, что перезапуск недоступен.

## Сессия 4: PR-события (📋) и self-mute

Ловушка: все события полигона создаешь ты сам. Если в `/github` привязан
логин Glitchy-Sheep, бот заглушит твои собственные события (self-mute) -
и это первый тест: привяжи логин, сделай `make comment`/`make review` и
убедись в тишине. Потом отвяжи логин и прогони:

```sh
make review PR=<n>              # "ревью": вердикт comment + текст
make review-comment PR=<n>      # inline-комментарий: file:line + ссылка на тред
make reply PR=<n> COMMENT=<id>  # ответ в треде - самый сложный кейс детекции
make draft PR=<n> && make ready PR=<n>   # "переведен в черновик" / "готов к ревью"
make close PR=<n>               # "закрыт без мержа"; 📋-подписка на PR остается
make reopen PR=<n>              # "переоткрыт" - подписка продолжает работать
make merge PR=<n>               # "влит" + кто влил; подписка retired
```

PR-события не supersede-ятся (это факты таймлайна) - проверь, что
история сообщений сохраняется.

## Сессия 5: kinds и краевые случаи

```sh
make pr-timeout        # джоба убита таймаутом: conclusion cancelled, "упала · таймаут"/🚫
make pr-cancel-me      # затем make cancel PR=<n>: 🚫 отмена на FE, ✅ BE на том же head
make commit-status PR=<n> STATE=pending   # KindStatus входит в jobs-подписку
make commit-status PR=<n> STATE=error     # терминальный сразу при обнаружении (U-12),
                                          # без лога, rerun: "на стороне CI"
make pr-broken-workflow  # ран без джоб: jobs-подписка молчит - это правильно
make pr-dual-workflow    # два "Build FE" с разными job ID: должны прийти ОБА
                         # (зеленый и красный), без слипания дедупом
make setup-env && make pr-approval   # ран висит в waiting: как бот покажет гейт?
make approve RUN=<id>                # или make reject RUN=<id> (даст failure)
```

## Сессия 6: нагрузка и статус

```sh
make storm N=5        # много PR у автора за один цикл опроса: снапшоты,
                      # backfill-стоимость подписки (U-02), очередь доставки
make pr-all-fail      # шторм падений: 4 сообщения с логами разом
```

Во время активных джоб посмотри `/status` (живые джобы, а не "нет
активных"), `/subscriptions`. Под нагрузкой следи за логом бота: дропы
очереди доставки сейчас тихие (U-17+).

## Финал

```sh
make cleanup          # закрыть все sbx/* PR и удалить ветки
```

В Telegram: `/subscriptions` - убрать тестовые подписки, чтобы дев-бот
не поллил зря.

## Отладка уровнем ниже

Если непонятно, бот или SDK: тот же полигон смотрится голым ghwatch
(сырые события без Telegram):

```sh
cd ~/Sources/personal/git-github/github-build-robot
GITHUB_TOKEN=$(gh auth token) go run ./examples/ghwatch \
  --repo Glitchy-Sheep/ci-events-playground --user Glitchy-Sheep \
  --job 'glob:Build *' --interval 10s --fetch-logs --log-tail 30
```

Учти: ghwatch не включает EventFamilyPR, PR-события в нем не видны.

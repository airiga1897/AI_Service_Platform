# healthcheck

Простой CLI, который читает `services.yml` и опрашивает HTTP healthcheck-
эндпойнты выбранных рантайм-инстансов в выбранном окружении (`local`,
`preprod`, `prod`). Используется для быстрой проверки «жив/не жив» всех
текущих сайтов и любых будущих сайтов/ботов; задумана как основа для
будущих rollback-решений в CI.

## Что делает

1. Берёт список инстансов из `runtime_instances` в `services.yml`.
2. Для каждого инстанса берёт `healthcheck.path`,
   `healthcheck.expected_status`, `healthcheck.timeout_seconds` и каждый
   домен из `domains.<env>`.
3. Формирует URL:
   - для `env=local` домен уже содержит схему и порт
     (`http://localhost:<port>`) — путь добавляется как есть;
   - для `env=preprod|prod` строка домена — голый хост, и собирается
     `https://<host><path>`.
4. Идёт `GET` через стандартный `urllib` с таймаутом из реестра (или
   `--timeout`), сравнивает фактический HTTP-статус с
   `expected_status` и записывает результат.

Зависимости: только стандартная библиотека (`urllib`) + `pyyaml` (нужен
общему загрузчику реестра `tools/_lib/registry.py`). Никаких `requests`.

## CLI

```bash
python3 tools/healthcheck/healthcheck.py --env <local|preprod|prod> \
    [--instance <name> ...] [--timeout <sec>] [--json] \
    [--registry <path>]
```

- `--env` — обязательный, какое из множеств доменов опрашивать.
- `--instance` — можно повторять, чтобы ограничить набор инстансов;
  без него опрашиваются все инстансы.
- `--timeout` — переопределяет per-target таймаут из реестра.
- `--json` — печатает структурированный отчёт (для CI/agents). По
  умолчанию — человекочитаемая таблица.
- `--registry` — альтернативный путь до `services.yml` (для тестов).

### Exit-коды

- `0` — все цели либо `ok`, либо `skipped`.
- `1` — есть хотя бы одна цель со статусом `fail`.
- `2` — ошибка конфигурации (неизвестный инстанс/окружение, невалидный
  CLI-ввод, нечитаемый `services.yml`).

## Поведение для placeholder-доменов

Любой домен из reserved TLD `.invalid` (RFC 6761) — например
`demo-aromaflow.example.invalid` — помечается как
`status: skipped, reason: placeholder-domain`. Такие цели **не** считаются
фейлами, потому что они заведомо не должны резолвиться в DNS. Когда у
инстанса появится реальный домен, он перестанет попадать в skipped и
начнёт реально опрашиваться.

Инстансы, у которых в выбранном окружении просто нет доменов
(`domains.<env>: []`), также попадают в `skipped` с причиной `no-domains`.

Production-домен с `site_runtime.publication.state: planned` ещё не считается
опубликованным и попадает в `skipped` с причиной `publication-planned`. Сетевой
опрос начинается только после отдельного перевода публикации в `active`.

## Plaintext vs HTTPS

- `local` — берётся то, что лежит в реестре (как правило,
  `http://localhost:<port>`); схема и порт не подменяются.
- `preprod` / `prod` — всегда `https://`. Для опроса plaintext-эндпойнта
  на удалённой ноде задумано использовать туннель через SoftEther +
  HAProxy, не через этот инструмент.

## Формат JSON-отчёта (`--json`)

```json
{
  "env": "preprod",
  "summary": {"total": 4, "ok": 1, "fail": 0, "skipped": 3},
  "results": [
    {
      "instance": "aromaflow-work",
      "env": "preprod",
      "url": "https://site.mine-craft.su/health/",
      "status": "ok",
      "http_status": 200,
      "expected_status": 200,
      "latency_ms": 42.7,
      "error": null,
      "reason": null
    },
    {
      "instance": "aromaflow-demo",
      "env": "preprod",
      "url": "https://demo-aromaflow.example.invalid/health/",
      "status": "skipped",
      "http_status": null,
      "expected_status": 200,
      "latency_ms": null,
      "error": null,
      "reason": "placeholder-domain"
    }
  ]
}
```

`status` всегда один из `ok`, `fail`, `skipped`. Поле `error` заполняется
для `fail` (например `unexpected-status: got 500, expected 200`,
`timeout after 5.0s`, `url-error: ...`). Поле `reason` заполняется для
`skipped` (`placeholder-domain`, `no-domains`, `publication-planned`).

## Примеры

```bash
# Все 4 инстанса, локально.
python3 tools/healthcheck/healthcheck.py --env local

# Только два сайта AromaFlow в preprod, JSON-отчёт.
python3 tools/healthcheck/healthcheck.py --env preprod \
    --instance aromaflow-work --instance aromaflow-demo --json

# Все инстансы в prod (у трёх из четырёх не будет доменов → skipped).
python3 tools/healthcheck/healthcheck.py --env prod

# Прижать таймаут до 2 секунд (полезно в CI).
python3 tools/healthcheck/healthcheck.py --env preprod --timeout 2

# Один инстанс, любой реестр.
python3 tools/healthcheck/healthcheck.py --env preprod \
    --instance aromaflow-work --registry /tmp/services.yml
```

## Что вне скоупа

- Принятие решений о rollback — этот инструмент только отчитывается.
  Логика rollback'а живёт в `.github/workflows/rollback.yml` и в
  будущем оркестраторе.
- Опрос внутренних метрик / Redis / Postgres — только HTTP healthcheck-
  пути.
- Хождение в SoftEther/management-порты.

## Тесты

```bash
python3 -m unittest discover -s tools/healthcheck/tests -t .
```

Тесты мокируют `urllib.request.urlopen` и проверяют построение URL,
обработку placeholder-доменов, exit-коды для смешанных результатов и
формат JSON-вывода.

# Реализация tools/healthcheck

## What & Why
`tools/healthcheck/` сейчас пустой. Нужен простой CLI, который читает `services.yml` и опрашивает healthcheck-эндпойнты выбранных рантайм-инстансов в выбранном окружении (`local`/`preprod`/`prod`). Это даёт быстрый способ проверить «жив/не жив» все 4 текущих сайта и любые будущие сайты/боты, а также служит основой для будущих rollback-решений в CI.

## Done looks like
- Есть CLI: `python3 tools/healthcheck/healthcheck.py --env <local|preprod|prod> [--instance <name> ...] [--timeout <sec>] [--json]`.
  - Без `--instance` опрашивает все инстансы, у которых в выбранном окружении есть домены.
  - `--json` печатает структурированный отчёт (для CI/agents); по умолчанию — человекочитаемая таблица.
  - Exit code: `0` — все ок; `1` — есть фейлы; `2` — ошибка конфигурации/CLI.
- Для каждого инстанса берёт `healthcheck.path`, `healthcheck.expected_status`, `healthcheck.timeout_seconds` из `services.yml` и каждый домен из `domains.<env>`; формирует `https://<domain><path>` (для `local` — как есть, ожидается `http://localhost:<port>`).
- Не использует тяжёлых зависимостей: только стандартная библиотека (`urllib`) + `pyyaml` (уже стоит). Никаких `requests`.
- Корректно обрабатывает: таймауты, DNS-фейлы, нерезолвящиеся домены-заглушки (`*.example.invalid` помечаются как `skipped: placeholder-domain`, не как фейл).
- Не делает деструктивных действий и никаких записей наружу.
- В `tools/healthcheck/README.md` описаны: использование, формат JSON-отчёта, поведение для plaintext/HTTPS, поведение для placeholder-доменов, примеры запусков для всех 4 инстансов.
- Добавлен smoke-тест `tools/healthcheck/tests/`, который мокирует `urllib` и проверяет:
  - корректное построение URL по `services.yml`;
  - правильный exit-code при микс-результатах (часть ок, часть фейл, часть skipped);
  - корректный JSON-вывод.

## Out of scope
- Принятие решений о rollback — только отчёт. Логика rollback'а живёт в `.github/workflows/rollback.yml`/будущем оркестраторе.
- Опрос внутренних метрик/Redis/Postgres — только HTTP healthcheck-пути.
- Хождение в SoftEther/management-порты.

## Steps
1. **Загрузка реестра** — использовать общий загрузчик `tools/_lib/registry.py` (если он уже создан задачей render-compose) или временный локальный, с последующим объединением.
2. **Сборка целей** — для каждого выбранного инстанса и окружения собрать список `(instance, env, domain, url, expected_status, timeout)` с понятной обработкой placeholder-доменов.
3. **Опрос** — последовательный (или с небольшим thread-pool'ом) HTTP-GET через `urllib.request` с таймаутом; собрать `status_code`, `latency_ms`, `error`.
4. **Отчёт** — человекочитаемая таблица + `--json` режим; финальный exit-code по агрегату.
5. **Тесты + README** — smoke-тесты с моками + `tools/healthcheck/README.md`.

## Relevant files
- `tools/healthcheck/README.md`
- `services.yml`
- `tools/validate-services-yml/validate_services_yml.py`

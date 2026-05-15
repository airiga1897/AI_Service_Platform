# CI и pre-commit интеграция

## Зачем и почему
Сейчас `.github/workflows/validate.yml` запускает только `validate_services_yml.py` и пару `test -d`. После появления расширенного валидатора, `render-compose` и `healthcheck` нужно:
- автоматически проверять их в CI на каждый PR/push в main;
- ловить дрейф между `services.yml` и сгенерированными compose-файлами;
- иметь локальный pre-commit hook, чтобы те же проверки прогонялись до коммита.

Это закрывает контур качества для всех 4 текущих инстансов и любых будущих сайтов/ботов, добавляемых через `services.yml`.

## Критерии готовности
- `.github/workflows/validate.yml` обновлён:
  - кеширует pip-зависимости;
  - запускает расширенный `validate_services_yml.py` (с `--strict`, если флаг реализован);
  - запускает `render-compose --check` для всех инстансов и фейлится при расхождении сгенерированного и закоммиченного compose;
  - запускает unit/smoke тесты `tools/validate-services-yml/tests/`, `tools/render-compose/tests/`, `tools/healthcheck/tests/`;
  - не запускает реальный сетевой healthcheck (он не должен падать из-за внешних сетей; в CI healthcheck гоняется только моками внутри тестов).
- Добавлен `.pre-commit-config.yaml` в корне репозитория со следующими хуками:
  - `validate-services-yml` — локально запускает валидатор;
  - `render-compose-check` — локально запускает `render_compose.py --stack all --check`;
  - `python-tests` (опционально) — гоняет smoke-тесты инструментов;
  - стандартные `trailing-whitespace`, `end-of-file-fixer`, `check-yaml` из `pre-commit-hooks`.
- Добавлен раздел в `docs/CI_CD.md`:
  - что делает CI на PR/push;
  - как поставить pre-commit локально (`pip install pre-commit && pre-commit install`);
  - как запустить полный набор проверок одной командой (`make check` или эквивалент).
- Добавлен `Makefile` (или `tasks.py`/`justfile` — на усмотрение исполнителя, по умолчанию `Makefile`) с целями:
  - `make validate` — валидатор;
  - `make render-check` — render-compose --check;
  - `make test` — все smoke-тесты;
  - `make check` — всё вместе.
- Replit-воркфлоу `Validate services.yml` обновлён, чтобы запускать `make check` (или эквивалент), а не только валидатор; по-прежнему console-workflow, без портов.
- Все хуки и CI-шаги проходят на текущем состоянии репозитория.

## Вне скоупа
- Деплой/rollback воркфлоу (`.github/workflows/deploy.yml`, `rollback.yml`) — не трогаем в этой задаче.
- Реальные сетевые healthcheck'и в CI (только моки).
- Подписывание/публикация артефактов.

## Шаги
1. **CI-обновление** — переписать `.github/workflows/validate.yml`: матрица Python (3.11), кеш pip, шаги для validator/render-check/tests; убедиться, что время прогона разумное.
2. **pre-commit** — добавить `.pre-commit-config.yaml`, настроить локальные хуки (`language: system` или `language: python` с `entry`/`args`), задокументировать установку.
3. **Makefile** — добавить корневой `Makefile` с целями `validate`, `render-check`, `test`, `check`.
4. **Replit-workflow** — переключить команду воркфлоу `Validate services.yml` на `make check` (или эквивалент), убедиться, что он по-прежнему «зелёный».
5. **Документация** — обновить `docs/CI_CD.md` и `README.md` («How to develop locally»: pre-commit + make check).
6. **Регрессия** — прогнать всё локально и убедиться, что CI проходит на текущем коде.

## Затрагиваемые файлы
- `.github/workflows/validate.yml`
- `.github/workflows/deploy.yml`
- `.github/workflows/rollback.yml`
- `docs/CI_CD.md`
- `README.md`
- `replit.md`
- `tools/validate-services-yml/validate_services_yml.py`
- `tools/render-compose/README.md`
- `tools/healthcheck/README.md`

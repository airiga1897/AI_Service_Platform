# Реализация tools/render-compose

## Зачем и почему
Сейчас `tools/render-compose/` — пустая папка с README-заглушкой, а `infra/stacks/{aromaflow-work,aromaflow-demo,ai-retail-mvp,ai-retail-dev}/` хранят per-stack Compose. Нужен генератор, который превращает `services.yml` + шаблоны в готовые `docker-compose.<stack>.yml`, чтобы добавление нового инстанса (включая будущие сайты и Telegram-ботов) сводилось к правке `services.yml` и шаблона, а не ручному копированию compose-файлов.

## Критерии готовности
- Есть CLI: `python3 tools/render-compose/render_compose.py --stack <stack-name> [--out <path>] [--check]`.
  - `--stack all` — рендерит все рантайм-инстансы из `services.yml`.
  - `--check` — рендерит во временный файл и сравнивает с тем, что лежит в `infra/stacks/<stack>/docker-compose.<stack>.yml`; выходит ненулевым кодом при расхождении (для CI).
  - Без `--out` пишет в `infra/stacks/<stack>/docker-compose.<stack>.yml`.
- Источник данных: `services.yml` (порты, env.prefix, env.file, имена БД/volumes/контейнеров, healthcheck).
- Шаблоны лежат в `tools/render-compose/templates/` — отдельные шаблоны для типов `django-site`, `django-react-site`, `telegram-bot` (последний — заготовка под будущих ботов из `future_service_template.bot`).
- Генерируемый compose-файл:
  - использует `containers.future` как имена сервисов (web/frontend/db/redis/nginx);
  - подставляет порты из `local.*_port`;
  - подключает `env_file: ../../<env.file>`;
  - содержит healthcheck для web-сервиса по `healthcheck.path`;
  - содержит volumes из `data.volumes`;
  - содержит явный комментарий-шапку «GENERATED FILE — do not edit by hand. Source: services.yml + tools/render-compose/templates».
- Существующие `infra/stacks/*/docker-compose.*.yml` либо приведены к выводу генератора, либо явно помечены как legacy в README соответствующего стека (без слома существующих деплоев).
- В `tools/render-compose/README.md` описано: как запускать, где шаблоны, как добавить новый тип сервиса, как использовать `--check` локально и в CI.
- Добавлены smoke-тесты `tools/render-compose/tests/`: рендер каждого из 4 инстансов завершается без ошибок, результат — валидный YAML, в нём есть ожидаемые ключи (`services`, имена контейнеров из `containers.future`).

## Вне скоупа
- Генерация конфигов HAProxy/Nginx/SoftEther — отдельная будущая работа.
- Реальный запуск Docker в Replit — здесь только генерация файлов.
- Изменения схемы `services.yml`.
- CI-хук `--check` — будет добавлен в задаче CI/pre-commit.

## Шаги
1. **Дизайн шаблонов** — определить минимальный шаблонный язык (Jinja2 — допустимая зависимость; добавить в `pyproject.toml`/requirements валидатора отдельно от валидатора, чтобы валидатор остался зависящим только от `pyyaml`).
2. **Загрузка реестра** — переиспользовать парсинг `services.yml` (вынести общий загрузчик в `tools/_lib/registry.py`, чтобы и валидатор, и render-compose, и healthcheck могли его использовать; сохранить обратную совместимость существующего валидатора).
3. **Шаблоны** — написать `templates/django-site.yml.j2`, `templates/django-react-site.yml.j2`, `templates/telegram-bot.yml.j2`.
4. **CLI** — реализовать рендер с флагами `--stack`, `--out`, `--check`, понятными ошибками при отсутствующем стеке/шаблоне.
5. **Согласование с infra/stacks/** — для 4 текущих инстансов либо обновить файлы под вывод генератора, либо в README стека пометить их как legacy и положить рядом сгенерированный файл `docker-compose.<stack>.generated.yml`.
6. **Тесты + README** — smoke-тесты + обновлённый `tools/render-compose/README.md`.

## Затрагиваемые файлы
- `tools/render-compose/README.md`
- `tools/validate-services-yml/validate_services_yml.py`
- `services.yml`
- `infra/stacks/aromaflow-work`
- `infra/stacks/aromaflow-demo`
- `infra/stacks/ai-retail-mvp`
- `infra/stacks/ai-retail-dev`

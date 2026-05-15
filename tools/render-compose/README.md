# render-compose

Генерирует per-stack файлы `docker-compose.<stack>.yml` для каждого
рантайм-инстанса, объявленного в `services.yml`. Добавление нового
инстанса (нового сайта или будущего Telegram-бота) сводится к
«поправить `services.yml` + выбрать нужный шаблон» вместо ручного
копирования compose-файлов.

## Как это устроено

1. `services.yml` — единственный источник правды (порты, env-префикс и
   файл, имена контейнеров, имя БД, путь и таймаут healthcheck, тома).
2. Поле `type` соответствующего проекта выбирает шаблон из
   `tools/render-compose/templates/`:
   - `django-site.yml.j2` — Django backend + frontend (используется
     инстансами AromaFlow).
   - `django-react-site.yml.j2` — Django backend (`*-web`) + Vite-dev
     frontend (`*-frontend-dev`) (используется инстансами AI_E_Retail).
   - `telegram-bot.yml.j2` — заготовка под будущие aiogram3-боты,
     объявленные с `type: telegram-bot` и обязательными полями
     `future_service_template.bot`.
3. Генератор пишет
   `infra/stacks/<stack>/docker-compose.<stack>.yml`. Каждый
   сгенерированный файл начинается с шапки
   `# СГЕНЕРИРОВАННЫЙ ФАЙЛ — не редактируйте вручную.`.

## CLI

Сгенерировать один стек в его канонический путь:

```bash
python3 tools/render-compose/render_compose.py --stack aromaflow-work
```

Сгенерировать все рантайм-инстансы:

```bash
python3 tools/render-compose/render_compose.py --stack all
```

Записать в произвольный путь (только для одного стека):

```bash
python3 tools/render-compose/render_compose.py \
  --stack aromaflow-demo --out /tmp/compose.yml
```

Режим проверки — рендерит в память, сравнивает с файлом на диске,
возвращает ненулевой код при расхождении. Предназначен для CI и
pre-commit (задача #5):

```bash
python3 tools/render-compose/render_compose.py --stack all --check
```

Опциональный `--registry path/to/services.yml` позволяет тестам
подменять реестр без правки канонического файла.

## Как добавить новый тип сервиса

1. Добавьте шаблон `tools/render-compose/templates/<type>.yml.j2`.
   Используйте Jinja2-разделители `<<` / `>>` — тогда литеральные
   shell-подстановки `${VAR}` не нужно экранировать.
2. Проставьте `projects.<name>.type: <type>` в `services.yml`.
3. Если тип — `site` или `telegram-bot`, у инстанса должен быть
   объявлен `type: <site|telegram-bot>`, чтобы валидатор обеспечил
   обязательные поля из соответствующего
   `future_service_template.<key>.required`.
4. Расширьте `_build_context` в `render_compose.py`
   переменными, которые нужны новому шаблону.
5. Перезапустите
   `python3 tools/render-compose/render_compose.py --stack all`
   и закоммитьте сгенерированные файлы.

## Тесты

Smoke-тесты лежат в `tools/render-compose/tests/`. Они рендерят каждый
известный инстанс, проверяют, что результат — валидный YAML с нужными
именами сервисов и томов, и запускают CLI с `--check` против
зафиксированных compose-файлов.

```bash
python3 -m unittest discover -s tools/render-compose/tests -t .
```

Зависимости: `pyyaml`, `jinja2` — обе объявлены в `pyproject.toml`.

## Связь с `infra/stacks/`

Каждый `infra/stacks/<stack>/docker-compose.<stack>.yml` — это
сгенерированный артефакт. Меняйте `services.yml` или шаблон и
перезапускайте генератор. README каждого стека говорит то же самое.

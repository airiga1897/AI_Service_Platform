# CI и публикация образа AI_E_Retail в GHCR

## Назначение

Этот план описывает продуктовый CI для репозитория `AI_E_Retail` и передачу
готового Docker-образа в `AI_Service_Platform`. Он дополняет планы
[подготовки приватного образа](site-runtime-private-image-staging.md) и
[ручного rollout Site Runtime](manual-site-runtime-rollout-before-github-cd.md).

Граница ответственности остаётся неизменной:

- `AI_E_Retail` проверяет продукт, собирает production-образ и публикует его в
  приватный GHCR;
- `AI_Service_Platform` принимает неизменяемый image ref, проверяет его,
  доставляет на вычисленный целевой узел и позднее выполняет rollout через
  generic `site_runtime`;
- исходный код продукта не копируется в платформенный репозиторий, а образ не
  собирается на управляемых VPS.

## Исходное состояние на 2026-07-14

В локальном и опубликованном branch `feature/toplat01` репозитория
`airiga1897/AI_E_Retail` уже существует `.github/workflows/ci.yml`. В нём
подготовлены:

- lint backend через Ruff и mypy;
- backend-тесты в восьми параллельных чанках;
- проверки Django migrations, OpenAPI и покрытия endpoint-ов документацией;
- typecheck, Vitest и production build frontend;
- smoke-тесты генераторов env-файлов;
- аудит Python- и npm-зависимостей;
- сборка тестового Docker stage и запуск pytest в контейнере с PostgreSQL и
  Redis;
- публикация образа в GHCR после успешного push в `main`.

На момент фиксации плана GitHub API не показывает workflow в default branch
`main`, поэтому цепочка ещё не считается активированной. Кроме переноса
workflow в `main`, до первой публикации необходимо устранить два разрыва:

1. Publish job не задаёт `target: web`. Поскольку последним stage в Dockerfile
   является `test`, без явного target может быть опубликован тестовый образ.
2. Publish job не выводит и не сохраняет итоговый digest как канонический вход
   для платформы.

## Целевой контракт образа

Канонический репозиторий образа:

```text
ghcr.io/airiga1897/ai_e_retail
```

CI может публиковать удобные для человека теги commit SHA и `latest`, но ни
один изменяемый тег не является deployment identity. Единственный допустимый
вход платформенного развёртывания:

```text
ghcr.io/airiga1897/ai_e_retail@sha256:<64 шестнадцатеричных символа>
```

Production-образ должен:

- собираться из Docker stage `web` для `linux/amd64`;
- содержать OCI labels как минимум `org.opencontainers.image.source`,
  `org.opencontainers.image.revision` и `org.opencontainers.image.version`;
- не содержать dev/test-зависимости и registry credentials;
- запускаться с конфигурацией и секретами, переданными только во время runtime;
- не выполнять необратимые seed-операции при обычном старте;
- предоставлять согласованные health/readiness endpoints для `site_runtime`.

## Целевой алгоритм CI

### Pull request в `main`

1. Checkout точного commit PR.
2. Установка зафиксированных Python- и Node.js-зависимостей.
3. Параллельный запуск lint, typecheck, backend/frontend tests, migration check,
   OpenAPI checks и dependency audit.
4. Сборка Docker stage `test` с BuildKit cache.
5. Запуск временных PostgreSQL и Redis только внутри GitHub Actions.
6. Запуск контейнерных pytest.
7. Удаление временных контейнеров и volumes независимо от результата.
8. Запрет merge через required checks, если любой обязательный gate завершился
   ошибкой.

На PR image в GHCR не публикуется и платформенный rollout не запускается.

### Push в `main`

1. Повторить все обязательные quality gates на уже принятом commit.
2. Авторизоваться в GHCR встроенным `GITHUB_TOKEN` с минимальными правами
   `contents: read` и `packages: write`.
3. Собрать `target: web` для `linux/amd64`.
4. Проставить OCI labels и теги commit SHA; `latest` допускается только как
   необязательный навигационный тег.
5. Опубликовать образ в приватный GHCR.
6. Получить digest из `${{ steps.build.outputs.digest }}`.
7. Сформировать полный `repository@sha256:digest`, вывести его в GitHub Actions
   Summary и сохранить в небольшом JSON-артефакте сборки.
8. Не выполнять SSH, `docker compose up`, миграции или изменение placement из
   продуктового workflow.

Минимальный смысл publish step:

```yaml
- name: Сборка и публикация production-образа
  id: build
  uses: docker/build-push-action@v6
  with:
    context: .
    target: web
    platforms: linux/amd64
    push: true
    tags: ${{ steps.meta.outputs.tags }}
    labels: ${{ steps.meta.outputs.labels }}
```

## Передача образа платформе

До включения GitHub CD передача остаётся явной операторской операцией:

1. Оператор берёт полный digest reference из результата успешного CI.
2. Локально выполняет `site_runtime plan` для ровно одного instance.
3. Выполняет `site_runtime stage-image -Check`.
4. После проверки выполняет `site_runtime stage-image` без `-Check`.
5. Платформа скачивает приватный образ на рабочей станции, доставляет tar по
   управляемому маршруту и загружает его в Docker целевого узла.
6. GHCR credentials не сохраняются ни на orchestration node, ни на целевом VPS.
7. Receipt фиксирует distribution digest, Docker config image ID, platform,
   transport tag и OCI labels.

Подготовка образа не запускает AI_E_Retail, не выполняет миграции, не создаёт
volumes и не добавляет public route. Реальный `site_runtime apply` включается
отдельно после прохождения runtime acceptance.

## План реализации

### Этап 1. Исправить продуктовый workflow

- добавить `id: build`, `target: web` и `platforms: linux/amd64` в publish job;
- нормализовать имя GHCR repository к нижнему регистру;
- публиковать commit SHA tag и при необходимости `latest`;
- вывести полный digest reference в job summary;
- сохранить JSON-артефакт с repository, commit SHA, digest и timestamp;
- проверить, что publish job зависит от всех обязательных quality gates.

### Этап 2. Активировать CI в GitHub

- открыть PR из `feature/toplat01` в `main`;
- добиться успешного выполнения всех проверок на PR;
- настроить branch protection и required checks для `main`;
- влить workflow в `main`;
- подтвердить первый успешный push workflow и появление private package в GHCR;
- проверить pull образа по digest с операторской рабочей станции.

### Этап 3. Подтвердить совместимость с платформой

- передать опубликованный digest в `site_runtime plan`;
- выполнить `stage-image -Check`, затем `stage-image`;
- повторить staging того же digest и подтвердить `already_loaded: true`;
- сверить OCI labels, `linux/amd64`, distribution digest и config image ID;
- убедиться, что контейнеры, volumes, миграции и routes не изменились.

### Этап 4. Подготовить будущий CD

Этот этап начинается только после ручной приёмки `site_runtime apply`, upgrade и
rollback. GitHub CD должен:

- принимать `instance`, environment и полный immutable `image_ref`;
- подключаться только к активному orchestration node;
- вызывать тот же platform service wrapper, который проверен вручную;
- публиковать deployment journal и health summary;
- использовать GitHub Environment approval для production;
- не хранить отдельные SSH-ключи для каждого VPS;
- не менять placement и не откатывать схему БД автоматически.

Продуктовый CI может инициировать явный `repository_dispatch` только после
включения этого gate. Самостоятельная реализация deploy-логики в
`AI_E_Retail` не допускается.

## Критерии готовности

CI и публикация считаются готовыми, когда одновременно выполнены условия:

- workflow находится в `main` и виден в GitHub Actions;
- PR нельзя влить при падении обязательных проверок;
- успешный push в `main` публикует именно stage `web` для `linux/amd64`;
- GitHub Actions Summary содержит полный digest reference;
- тот же reference доступен как машинно-читаемый JSON-артефакт;
- `docker pull repository@sha256:digest` возвращает ожидаемый образ;
- повторная сборка не меняет identity уже опубликованного digest;
- платформа принимает digest и отклоняет `latest` и другие mutable refs;
- staging не оставляет GHCR credentials на VPS и не запускает продукт;
- документация AI_E_Retail объясняет разработчику путь от PR до готового
  immutable image ref.

## Вне рамок этого плана

- автоматический production rollout;
- public edge route для AI_E_Retail;
- автоматический rollback схемы PostgreSQL;
- multi-architecture image;
- blue/green и canary deployment;
- перенос исходного кода AI_E_Retail в платформенный репозиторий.

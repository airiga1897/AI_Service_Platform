# Реальный deploy/rollback-пайплайн (ADR-0006) + guard заморозки MVP (ADR-0003)

## Зачем и почему

После follow-up #6 у платформы есть полный декларативный контур:
`services.yml` (канон) → `validate-services-yml` (strict) →
`render-compose` / `render-edge` (генераторы конфигов) → `healthcheck`
(проверка живости). Все четыре рантайм-инстанса материализуются
автоматически, дрейф ловится в `make check`/CI, ADR-серия (7 шт.)
согласована с кодом.

Главная незакрытая дыра — **ADR-0006**: политика «деплой только из
неизменяемых image refs» зашита в `services.yml.platform.source_policy`
и проверяется валидатором, но фактический `.github/workflows/deploy.yml`
и `rollback.yml` — пустые dry-run скелеты. То есть процесса деплоя
де-факто **нет**, есть только декларация.

Одновременно с этим закрывается «незакрытый хвост» **ADR-0003** —
заморозка `ai-retail-mvp` на релиз-теге. Это не самостоятельная
задача: enforcement физически живёт внутри deploy-пайплайна (отказ
катить mvp, если ref не из `ai-retail-mvp-v*` или не immutable image
ref). Делать его раньше `deploy.yml` — значит писать одноразовый
standalone-валидатор, который придётся выкинуть.

Это план **последовательной реализации**: сначала `deploy.yml`/
`rollback.yml`, внутри них — guard для MVP-заморозки. Параллельно —
небольшая подготовительная работа в `services.yml` и валидаторе,
чтобы deploy-пайплайн читал не строки в комментариях, а явные поля
с типизированной схемой.

После этого остаются только мелкие пункты из других ADR (см. раздел
«Следующие шаги после этого плана»).

## Принципы

1. **Канон деплоя — `services.yml`.** Deploy-пайплайн читает
   `runtime_instances.<name>.deploy` и `platform.source_policy`,
   ничего не хардкодит.
2. **Image ref — единственный артефакт.** `deploy.yml` принимает
   image ref (digest или коммит-SHA-тег), не git-ref.
3. **Заморозка — поле в реестре, проверка — в валидаторе и в
   deploy.** Никаких «правил из комментариев».
4. **Rollback — это re-deploy предыдущего ref'а**, а не git-checkout.
   Источник предыдущего ref'а — артефакт предыдущего деплоя
   (хранится в репозитории deploy-state или GH Actions cache).
5. **Безопасные дефолты.** Любой реальный rollout идёт через
   `workflow_dispatch` (ручной trigger), preprod/prod — через
   GitHub Environments с required reviewers.
6. **Поэтапность.** Сначала deploy в **preprod-окружение одного
   инстанса** (`ai-retail-dev`, как наименее болезненный), затем
   расширение на остальные.

## Скоуп

### В скоупе
- Расширение `services.yml` полями для deploy-контракта (см. ниже).
- Расширение валидатора `validate-services-yml` под новые поля,
  включая жёсткую проверку `frozen: true` инстансов.
- Реализация `.github/workflows/deploy.yml`:
  - inputs: `instance`, `image_ref`, `environment`.
  - guard'ы: source_policy (immutable ref), frozen-instance pattern,
    наличие инстанса в `services.yml`, наличие environment.
  - выполнение: SSH в целевой VPS, `docker compose pull` + `up -d`
    с подменой image-тега через ENV.
  - запись задеплоенного ref'а в deploy-state (git-tag или
    GHA artifact).
  - post-deploy healthcheck (через `tools/healthcheck/`).
- Реализация `.github/workflows/rollback.yml`:
  - inputs: `instance`, `environment` (опционально `to_ref`).
  - источник «предыдущий ref» — deploy-state.
  - тот же runner-flow, что и deploy.
- Документация: `docs/DEPLOYMENT.md` обновляется с реальными
  командами; runbook'и «деплой выбранного стека» и «откат выбранного
  стека» переезжают из «запланированных» в «рабочие» в
  `docs/RUNBOOKS.md`.
- Чистка `bootstrap_ref` в `projects.*.source` (когда продуктовые
  ветки/теги стабилизируются) — отдельным мелким коммитом.

### Вне скоупа
- Реальные SSH-ключи и vault-секреты — заполняются через GitHub
  Environments оператором, в репозиторий не коммитятся.
- TLS/Certbot и реальный edge rollout (HAProxy/Nginx на VPS) —
  отдельная сессия после того, как deploy-пайплайн отработает на
  одном инстансе.
- GeoPolicy-сервис (ADR-0007) — это отдельный продукт, вне границ
  инфра-репо.
- Условный валидатор по `type: telegram-bot` (часть ADR-0004) —
  имеет смысл делать в момент появления первого реального бота.

## Декомпозиция: 5 задач (G → K)

Порядок: G → H → I → J → K. После каждой — `make check` зелёный,
осмысленный коммит-чекпоинт. K — опциональный.

### Задача G — расширение `services.yml` под deploy-контракт

**Цель:** добавить в реестр явные поля, которые потом будет читать
`deploy.yml` и валидатор. Никакого исполняемого кода — только схема.

**Изменения:**

1. В `runtime_instances.<name>` добавить блок `deploy`:
   ```yaml
   deploy:
     allowed_image_ref_pattern: "^ghcr\\.io/airiga1897/aromaflowai:[0-9a-f]{40}$"
     frozen: false                       # true только для ai-retail-mvp
     frozen_image_ref_pattern: null      # для ai-retail-mvp: "^...:ai-retail-mvp-v.*$"
     environments:                       # уже есть, дополнить:
       preprod:
         vps: vps2
         compose_file: infra/stacks/<instance>/docker-compose.<instance>.yml
         deploy_state_tag_prefix: "deploy/<instance>/preprod/"
       prod:
         vps: vps1
         compose_file: infra/stacks/<instance>/docker-compose.<instance>.yml
         deploy_state_tag_prefix: "deploy/<instance>/prod/"
   ```
2. Для `ai-retail-mvp` выставить `frozen: true` и заполнить
   `frozen_image_ref_pattern` явно — это машиночитаемая фиксация
   решения из ADR-0003.
3. Перерендерить compose'ы (новых полей в шаблонах быть не должно —
   `deploy` потребляется только пайплайном, не compose'ом). `make
   render-check` должен остаться зелёным без изменений в
   `infra/stacks/`.

**Критерии готовности:**
- В `services.yml` все 4 инстанса имеют валидный блок `deploy`.
- `make check` зелёный (валидатор пока не проверяет новые поля
  жёстко — это задача H).
- В comments `services.yml` явно указано, что блок `deploy`
  потребляется только GitHub Actions, не compose-генератором.

**Файлы:** `services.yml`.

---

### Задача H — расширение валидатора под deploy-поля

**Цель:** превратить новые поля из задачи G в жёсткий контракт,
чтобы любой PR, ломающий заморозку MVP, падал на `make check`.

**Изменения:**

1. В `tools/validate-services-yml/validate_services_yml.py`
   добавить чек-функции:
   - `check_deploy_block_present` — у каждого `runtime_instances.*`
     должен быть `deploy` с непустым `allowed_image_ref_pattern`.
   - `check_frozen_instance_has_pattern` — если
     `deploy.frozen: true`, то `deploy.frozen_image_ref_pattern`
     обязателен и непустой.
   - `check_deploy_environments_match_vps_layout` — каждый
     `deploy.environments.*.vps` должен существовать в
     `platform.vps_layout`.
   - `check_pattern_is_valid_regex` — `allowed_image_ref_pattern`
     и `frozen_image_ref_pattern` парсятся через `re.compile`.
   - `check_pattern_consistency` — для frozen инстансов
     `allowed_image_ref_pattern` должен быть **подмножеством**
     `frozen_image_ref_pattern` (если оба заданы) или совпадать.
2. Добавить smoke-тесты в
   `tools/validate-services-yml/tests/test_validate.py` + 2-3
   broken-fixture'а:
   - `broken_deploy_missing.yml`, `broken_frozen_no_pattern.yml`,
     `broken_pattern_invalid_regex.yml`.
3. Обновить `docs/CI_CD.md` — упомянуть новые проверки.

**Критерии готовности:**
- Все новые проверки покрыты unit-тестами.
- `make check` зелёный.
- Попытка убрать `frozen: true` у `ai-retail-mvp` или подменить
  `frozen_image_ref_pattern` на «всё подряд» проваливает валидатор.

**Файлы:**
- `tools/validate-services-yml/validate_services_yml.py`
- `tools/validate-services-yml/tests/test_validate.py`
- `tools/validate-services-yml/tests/fixtures/broken_*.yml`
- `docs/CI_CD.md`

---

### Задача I — `.github/workflows/deploy.yml` (минимальный, но рабочий)

**Цель:** заменить dry-run скелет рабочим workflow для **одного
preprod-инстанса** (`ai-retail-dev` → vps2). Это тонкий вертикальный
срез — потом расширяется на остальные инстансы простым inputs-выбором.

**Дизайн workflow:**

```yaml
on:
  workflow_dispatch:
    inputs:
      instance:    { type: choice, options: [aromaflow-work, aromaflow-demo, ai-retail-mvp, ai-retail-dev] }
      environment: { type: choice, options: [preprod, prod] }
      image_ref:   { type: string }   # полный ref, например ghcr.io/.../...:<sha>

jobs:
  preflight:
    # 1. make check (как и в validate.yml).
    # 2. Прочитать services.yml, найти runtime_instances[instance].
    # 3. Проверить, что image_ref матчит allowed_image_ref_pattern.
    # 4. Если frozen=true — проверить, что image_ref матчит ТАКЖЕ frozen_image_ref_pattern.
    # 5. Резолвить deploy.environments[environment] → vps, compose_file.
    # 6. Не падать молча: выводить причину отказа в job summary.

  deploy:
    needs: preflight
    environment: ${{ inputs.environment }}   # GH Environment с required reviewers для prod
    steps:
      - SSH в целевой VPS (по deploy-key из GH Environment secrets).
      - cd в каталог стэка на VPS, scp/render свежий docker-compose.<instance>.yml.
      - Подмена image-тега через .env (IMAGE_REF=...) или через ENV-инжект в compose.
      - docker compose pull && docker compose up -d.
      - Ожидание healthcheck (через tools/healthcheck/healthcheck.py --env <environment> --instance <instance>).

  record:
    needs: deploy
    steps:
      - Записать задеплоенный ref в deploy-state:
        git tag deploy/<instance>/<environment>/<timestamp> <commit>
        с annotation, содержащей image_ref. Push tag.
      - Опубликовать summary с image_ref и URL healthcheck.
```

**Что **не** делаем в первой итерации:**
- Авто-trigger по push в main (только `workflow_dispatch`).
- Параллельный multi-instance deploy (по одному инстансу за раз).
- Канареечный rollout / blue-green (просто `up -d`, downtime
  ограничивается рестартом контейнера web).

**Критерии готовности:**
- Workflow запускается через UI GitHub Actions.
- Реально катит `ai-retail-dev` в preprod на vps2 из заданного
  image ref'а.
- Попытка задеплоить `ai-retail-mvp` с image ref'ом, не матчащим
  `frozen_image_ref_pattern`, падает на `preflight` с понятным
  сообщением.
- После деплоя — successful healthcheck и записанный deploy-tag.
- В `docs/DEPLOYMENT.md` обновлена процедура.

**Файлы:**
- `.github/workflows/deploy.yml` (полная переписка).
- `docs/DEPLOYMENT.md`.
- (опционально) `tools/_lib/registry.py` — helper для чтения
  `runtime_instances[instance].deploy`, чтобы preflight-шаг и
  валидатор использовали один и тот же код.

---

### Задача J — `.github/workflows/rollback.yml`

**Цель:** механический откат на предыдущий задеплоенный image ref
для выбранного `instance`/`environment`.

**Дизайн:**

```yaml
on:
  workflow_dispatch:
    inputs:
      instance:    { type: choice, ... }
      environment: { type: choice, options: [preprod, prod] }
      to_ref:      { type: string, required: false }  # если пусто — берём предпредыдущий deploy-tag

jobs:
  resolve:
    # 1. Если to_ref задан — валидируем по allowed_image_ref_pattern.
    # 2. Если не задан — git tag --list 'deploy/<instance>/<environment>/*' --sort=-creatordate,
    #    берём ВТОРОЙ (текущий — первый, целевой откат — второй).
    # 3. Извлекаем image_ref из annotation предыдущего тега.

  rollback:
    needs: resolve
    environment: ${{ inputs.environment }}
    steps:
      - тот же SSH-flow, что и в deploy.yml (фактически вызывает тот же
        reusable workflow или скрипт, передавая resolved image_ref).
      - Запись нового deploy-tag (rollback тоже становится точкой в
        истории, чтобы следующий rollback откатывал к предыдущему).
```

**Критерии готовности:**
- Откат успешно проходит на `ai-retail-dev/preprod`.
- При отсутствии предыдущего tag'а — внятная ошибка, не молчаливый
  падёж.
- Runbook «откат выбранного стека» в `docs/RUNBOOKS.md` переезжает
  в раздел «уже работающие процедуры».

**Файлы:**
- `.github/workflows/rollback.yml`.
- `docs/RUNBOOKS.md`.

---

### Задача K (опциональная) — чистка `bootstrap_ref` и расширение
на остальные инстансы

**Цель:** после того как первый реальный деплой через `deploy.yml`
прошёл, убрать накопленный техдолг.

**Изменения:**

1. Если в продуктовых репозиториях появились стабильные
   `develop`/`main`/release-теги — удалить `bootstrap_ref` из
   `projects.*.source` (закрытие техдолга из ADR-0006).
2. Прогнать `deploy.yml` на каждом из оставшихся инстансов
   (`aromaflow-demo`, `aromaflow-work`, `ai-retail-mvp` — последний
   с реальным `ai-retail-mvp-v*` тегом для проверки frozen-guard'а).
3. Обновить runbook «добавление нового рантайм-инстанса» —
   добавить шаг «заполнить блок `deploy` в `services.yml`».

**Критерии готовности:**
- `bootstrap_ref` либо удалён, либо явно отмечен как «всё ещё нужен,
  потому что …».
- Все 4 инстанса хотя бы раз задеплоены через workflow в preprod.
- Документация runbook'ов согласована.

**Файлы:**
- `services.yml`, `docs/DEPLOYMENT.md`, `docs/RUNBOOKS.md`.

## Зависимости и риски

- **Зависимость от внешних факторов:** GitHub Environments, SSH-доступ
  к VPS, наличие GHCR-образов в продуктовых репозиториях. Эти вещи
  настраиваются оператором; план фиксирует **что** нужно настроить, не
  **как** (это runbook).
- **Риск:** первый реальный SSH-деплой может вскрыть рассинхрон
  `infra/stacks/*/docker-compose.*.yml` с тем, что фактически лежит
  на VPS. Митигация: первый прогон — на `ai-retail-dev/preprod`, где
  downtime приемлем; рассогласование — **не** маскируем,
  устраняем правкой `services.yml` + перерендером.
- **Риск:** deploy-state как git-теги — простое решение, но плохо
  масштабируется при сотнях деплоев в день. Для текущих 4 инстансов
  и ручного `workflow_dispatch` — приемлемо. Если когда-нибудь
  понадобится автодеплой — вернёмся к этому решению (новый ADR).

## Что **не** входит в этот план

- Реализация GeoPolicy-сервиса (ADR-0007 → `planned-…`, отдельный
  продукт).
- Условный валидатор по `type: telegram-bot` и compose-шаблон бота
  (ADR-0004) — делать в момент появления первого реального бота.
- Мониторинг и alerting на VPS (Prometheus exporters сейчас только
  объявлены в Ansible-переменных) — отдельная сессия.
- Реальный rollout edge-конфигов (HAProxy/Nginx на VPS) с
  Certbot/ACME — отдельная сессия после того, как deploy-пайплайн
  отработает.

## Сводный чек-лист
- [ ] G — расширение `services.yml` блоком `deploy`
- [ ] H — расширение валидатора + broken-fixtures + тесты
- [ ] I — рабочий `deploy.yml` (минимальный, на одном preprod-инстансе)
- [ ] J — `rollback.yml`
- [ ] K — (опц.) чистка `bootstrap_ref` + расширение на остальные
  инстансы

После каждой задачи: `make check` зелёный, осмысленный
коммит-чекпоинт.

В конце: код-ревью архитектора по всему диффу, единый финальный
`mark_task_complete`.

## Следующие шаги **после** этого плана (горизонт 1-2 сессии)

В порядке приоритета:

1. **Реальный rollout edge на VPS** (HAProxy + per-site Nginx +
   Certbot/ACME). Сейчас инструмент `tools/render-edge/` готов и
   валидирует конфиги, но фактически их никто на VPS не катит. Это
   логически следующий шаг после рабочего `deploy.yml`.
2. **Мониторинг и alerting:** активация Prometheus exporters
   (объявлены в `infra/ansible/group_vars/prod.yml` и `backup.yml`,
   но не подняты), Uptime Kuma (объявлен, но не интегрирован с
   alerting-каналом), Telegram-уведомления о падениях.
3. **Условный валидатор по `type:`** (ADR-0004) — параллельно с
   первым реальным Telegram-ботом, когда он появится в одном из
   продуктовых репозиториев.
4. **GeoPolicy-сервис** (ADR-0007) — отдельный мини-проект,
   выходящий за границы этого репозитория. На стороне инфра-репо
   достаточно зафиксировать схему `data_outputs` (уже сделано).

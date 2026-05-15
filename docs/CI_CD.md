# CI/CD (непрерывная интеграция и доставка)

## Модель

Продукты собирают, платформа деплоит.

## Продуктовые репозитории

Продуктовые репозитории отвечают за:

- линт и тесты;
- сборку Docker-образов;
- публикацию образов в GHCR;
- опциональный `repository_dispatch` в платформенный репозиторий.

Имена веток описывают только политику источников/сборки. Временные feature-ветки фиксируются в `services.yml` как `bootstrap_ref` до тех пор, пока не появятся продуктовые `develop`, `main` или релиз-теги.

## Платформенный репозиторий

Этот репозиторий отвечает за:

- валидацию реестра сервисов и метаданных стеков;
- рендер конфигурации деплоя;
- деплой выбранных неизменяемых image refs в выбранные стеки на VPS;
- healthcheck-и и метаданные для rollback.

В качестве входов деплоя предпочтительны Docker image refs, помеченные коммит-SHA или релиз-тегом. Имя ветки не должно быть единственным идентификатором продакшен-деплоя.

## Deploy и rollback (GitHub Actions)

| Workflow | Назначение |
|----------|------------|
| [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) | `make check` + `tools/deploy/preflight.py`; SSH predeploy-check только для `ai-retail-dev` / `preprod` |
| [`.github/workflows/rollback.yml`](../.github/workflows/rollback.yml) | Re-deploy явного `to_ref`; deploy-state lookup пока не реализован |

Первый включённый сценарий: **`ai-retail-dev` → `preprod` → VPS2**. Production и остальные инстансы отклоняются намеренно.

`ai-retail-mvp` защищён полем `deploy.frozen: true` и regex `frozen_image_ref_pattern` в `services.yml` (валидатор + preflight).

## GitHub Environments (окружения)

Рекомендуемые окружения:

- `ai-retail-dev-preprod` — secrets для первого реального rollout (`SSH_HOST`, `SSH_USER`, `SSH_KEY`)
- `aromaflow-work`
- `aromaflow-demo`
- `ai-retail-mvp`
- `ai-retail-dev`
- `vps1-prod`
- `vps2-preprod`
- `vps3-management`

## Локальная разработка и pre-commit

Для повторения проверок CI локально предусмотрены `Makefile` и
`pre-commit`-хуки.

### Быстрая проверка одной командой

```bash
make check
```

Эта цель запускает:

- `make validate` — `tools/validate-services-yml/validate_services_yml.py --strict`
  (предупреждения валидатора трактуются как ошибки);
- `make render-check` — `tools/render-compose/render_compose.py --stack all --check`
  (фейлится, если сгенерированные `infra/stacks/<stack>/docker-compose.<stack>.yml`
  разошлись с текущим `services.yml`);
- `make render-edge-check` — `tools/render-edge/render_edge.py --check`
  (фейлится, если `infra/edge/haproxy/haproxy.cfg` или
  `infra/edge/nginx/sites/*.conf` разошлись с текущим `services.yml`);
- `make test` — smoke-тесты `tools/validate-services-yml/tests`,
  `tools/render-compose/tests`, `tools/render-edge/tests`,
  `tools/healthcheck/tests`, `tools/deploy/tests`.

Валидатор (`make validate`) дополнительно проверяет deploy-контракт в
`runtime_instances.*.deploy`: `allowed_image_ref_pattern`, `frozen`,
`environments.*.{vps,compose_file,deploy_dir,deploy_state_tag_prefix}`.

Алиас `make validate-strict` сохранён для обратной совместимости и
делает то же самое. Цель `make validate-lax` гонит валидатор без
`--strict` — нужна только для локальной отладки сообщений-варнингов.

### pre-commit

Включить локальные хуки:

```bash
pip install pre-commit
pre-commit install
pre-commit install --hook-type pre-push   # для smoke-тестов
```

Конфигурация — в `.pre-commit-config.yaml`. Хуки:

- стандартные `trailing-whitespace`, `end-of-file-fixer`, `check-yaml`
  из `pre-commit/pre-commit-hooks`;
- `validate-services-yml` — локально запускает валидатор реестра;
- `render-compose-check` — локально запускает `render_compose.py --stack all --check`;
- `render-edge-check` — локально запускает `render_edge.py --check`;
- `python-tests` — на стадии `pre-push` гоняет smoke-тесты всех
  инструментов (validator / render-compose / render-edge / healthcheck).

### CI на PR/push

`.github/workflows/validate.yml` запускается на каждый pull request и
push в `main` (а также вручную через `workflow_dispatch`):

1. Поднимает Python 3.11 с кешем pip-зависимостей.
2. Ставит `pyyaml` и `jinja2`.
3. Проверяет минимальный layout репозитория (наличие `services.yml`,
   `infra/stacks/*`, `infra/edge/softether`).
4. Запускает `make validate`, `make render-check`,
   `make render-edge-check`, `make test`.

Реальные сетевые healthcheck-и в CI не выполняются — модуль
`tools/healthcheck/` проверяется только моками в smoke-тестах.

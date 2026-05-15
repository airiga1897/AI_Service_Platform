# CI/CD

## Model

Products build, platform deploys.

## Product repositories

Product repositories are responsible for:

- lint and tests;
- Docker image build;
- publishing images to GHCR;
- optional `repository_dispatch` to platform repo.

Branch names describe source/build policy only. Temporary feature branches are recorded in `services.yml` as `bootstrap_ref` until product `develop`, `main`, or release tags are ready.

## Platform repository

This repository is responsible for:

- validating service registry and stack metadata;
- rendering deploy configuration;
- deploying selected immutable image refs to selected VPS stacks;
- healthchecks and rollback metadata.

Deploy inputs should prefer Docker image refs tagged with commit SHA or release tag. A branch name must not be the only production deployment identifier.

## GitHub Environments

Recommended environments:

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

- `make validate` — `tools/validate-services-yml/validate_services_yml.py`;
- `make render-check` — `tools/render-compose/render_compose.py --stack all --check`
  (фейлится, если сгенерированные `infra/stacks/<stack>/docker-compose.<stack>.yml`
  разошлись с текущим `services.yml`);
- `make test` — smoke-тесты `tools/validate-services-yml/tests`,
  `tools/render-compose/tests`, `tools/healthcheck/tests`.

Дополнительно есть `make validate-strict` — гонит валидатор с флагом
`--strict`, при котором предупреждения трактуются как ошибки. На текущем
реестре цель ожидаемо падает на варнинге `port=5000` (зарезервирован
Replit web preview), поэтому она не входит в `make check` и в CI.

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
- `python-tests` — на стадии `pre-push` гоняет smoke-тесты всех трёх
  инструментов.

### CI на PR/push

`.github/workflows/validate.yml` запускается на каждый pull request и
push в `main` (а также вручную через `workflow_dispatch`):

1. Поднимает Python 3.11 с кешем pip-зависимостей.
2. Ставит `pyyaml` и `jinja2`.
3. Проверяет минимальный layout репозитория (наличие `services.yml`,
   `infra/stacks/*`, `infra/edge/softether`).
4. Запускает `make validate`, `make render-check`, `make test`.

Реальные сетевые healthcheck'и в CI не выполняются — модуль
`tools/healthcheck/` проверяется только моками в smoke-тестах.

# Предложение Codex: deploy/rollback pipeline

Краткий разбор [`../../codex/plans/01-cursor-deploy-rollback-next-step.md`](../../codex/plans/01-cursor-deploy-rollback-next-step.md) и сопоставление с Replit-планом [`../../replit/plans/06-deploy-and-rollback-pipeline.md`](../../replit/plans/06-deploy-and-rollback-pipeline.md).

## Источник

Файл в `docs/codex/plans/` — **готовый промт для Cursor**, добавленный в коммите `Step #6`. Он ссылается на Replit #06 и ADR-0003/0006 как на канон.

## Цель milestone (Codex)

Реализовать deploy/rollback pipeline после infra-MVP, но **включить фактический rollout только для одного сценария**:

```
ai-retail-dev → preprod → VPS2
```

Жёсткие ограничения:

- без production deploy;
- без secrets, SSH keys, IP, `.env`, `inventory.ini` в git;
- без продуктового кода;
- не ломать validator, render-compose, render-edge, healthcheck;
- SoftEther/VPN не смешивать с product runtime deploy.

## Семь шагов реализации (Codex)

| # | Область | Что сделать |
|---|---------|-------------|
| 1 | `services.yml` | Для каждого `runtime_instances.*.deploy` добавить: `allowed_image_ref_pattern`, `frozen`, `frozen_image_ref_pattern`, `environments.<env>.{vps,compose_file,deploy_dir,deploy_state_tag_prefix}`. MVP: `ai-retail-mvp` с `frozen: true` и паттерном `ai-retail-mvp-v*`. |
| 2 | Валидатор | Проверять новые поля, regex, VPS из `platform.vps_layout`, пути compose, префиксы deploy-state, SoftEther-порты. Новые фикстуры/тесты. |
| 3 | `tools/deploy/preflight.py` | CLI: `--instance`, `--environment`, `--image-ref` → JSON с метаданными деплоя или ошибка. |
| 4 | `deploy.yml` | Job `preflight` (`make check` + preflight); deploy job только для `ai-retail-dev/preprod`, остальное — явный fail; SSH как guarded skeleton. Inputs: `instance`, `environment`, `image_ref` (убрать ручной `target_vps`). |
| 5 | `rollback.yml` | Inputs: `instance`, `environment`, опционально `to_ref`; без `to_ref` — fail (deploy-state lookup позже); preflight + rollback только `ai-retail-dev/preprod`. |
| 6 | Docs | `DEPLOYMENT.md`, `RUNBOOKS.md`, `CI_CD.md` — что включено сейчас, что намеренно выключено. |
| 7 | Проверки | Все существующие `make check` + тесты preflight + `git diff --check`. |

## Критерии приёмки (Codex)

- Deploy-контракт для всех 4 инстансов в `services.yml`.
- Валидатор отклоняет битый контракт.
- `preflight.py` отдаёт JSON для `ai-retail-dev/preprod`, режет невалидные/frozen refs.
- `deploy.yml` / `rollback.yml` не пустой dry-run: полный preflight + guarded path.
- В git нет секретов и продуктового кода.

## Сравнение с Replit #06

| Тема | Replit #06 | Codex (промт) |
|------|------------|---------------|
| Зачем | Закрыть дыру ADR-0006 + enforcement заморозки MVP (ADR-0003) | То же, сузить до первого вертикального сценария |
| Первый rollout | `ai-retail-dev`, preprod | `ai-retail-dev/preprod/VPS2` — совпадает |
| Deploy-state | Git-tag или GHA artifact для rollback | Rollback пока только с явным `to_ref`; lookup — follow-up |
| SSH deploy | В скоупе (с секретами вне репо) | Preflight полностью; SSH — skeleton если нет secrets |
| Workflow inputs | `instance`, `image_ref`, `environment` | То же; Codex **убирает** ручной `target_vps` |
| `preflight.py` | Подразумевается в плане | Явный путь и контракт CLI/JSON |
| Scope guard | GitHub Environments, workflow_dispatch | + явный whitelist только `ai-retail-dev/preprod` |

**Вывод:** Codex не противоречит Replit #06 — это **ужатая, исполнимая спецификация** того же milestone. Replit даёт «почему» и принципы; Codex — пошаговый промт с acceptance criteria для агента.

## Отличия от текущего `deploy.yml`

Сейчас в [`.github/workflows/deploy.yml`](../../../.github/workflows/deploy.yml):

- inputs: `instance`, `image_ref`, **`target_vps`** (ручной выбор);
- один job `dry-run` с `echo`.

Codex предлагает:

- inputs: `instance`, **`environment`**, `image_ref`;
- VPS и пути — только из `services.yml` через preflight;
- staged jobs: validate → preflight → guarded deploy.

## Связь с ветками `codex/*`

- Ветка **`codex/feature/prepare02`** — текущий infra-MVP (этот обзор).
- Ansible частично перенесён из `codex/feature/new_infra02` репозитория AromaFlowAI (см. [`infra/ansible/README.md`](../../../infra/ansible/README.md)).
- Следующая работа логично идёт в той же ветке или в `cursor/feature/deploy-preflight` после merge infra-MVP.

## Рекомендуемый порядок для Cursor

1. Merge infra-MVP в `main` (опционально squash).
2. Реализовать шаги 1–3 (контракт + валидатор + preflight) — можно без secrets.
3. Обновить workflows (4–5) и docs (6).
4. Прогнать `make check` и закоммитить.

Полный текст промта: [`../../codex/plans/01-cursor-deploy-rollback-next-step.md`](../../codex/plans/01-cursor-deploy-rollback-next-step.md).
